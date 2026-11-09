import Foundation
import NIO
import NIOHTTP1
import NIOPosix

/// Races an async operation against a timeout and returns whichever finishes first, cancelling
/// the loser. Used by ``MCPHTTPChannelHandler`` to bound how long an MCP HTTP request can occupy
/// a connection.
///
/// A standalone internal type rather than a method nested in the file-private
/// `MCPHTTPChannelHandler` specifically so `@testable import` can drive it directly — the channel
/// handler itself stays file-private since nothing outside this file talks to raw NIO channel
/// state, but the timeout race is a self-contained concurrency idiom worth covering on its own.
enum MCPRequestTimeoutRace {
    /// `group.cancelAll()` only *requests* cooperative cancellation — Swift concurrency cannot
    /// preempt synchronous, non-yielding code, so this guarantees the caller gets a response by
    /// the deadline, not that `operation` actually stops running by then. Call sites inside
    /// `MCPProtocolService` that can loop repeatedly (e.g. the pagination retry loop in
    /// `sessionsPage`) must add their own `Task.checkCancellation()` checkpoints for this deadline
    /// to actually free the MainActor sooner instead of only changing what gets written to the wire.
    ///
    /// - Parameters:
    ///   - timeout: Overridable for tests; production call sites use the default.
    ///   - onTimeoutExceeded: Overridable for tests so they can observe whether the timeout branch
    ///     actually ran without depending on `os_log` output. Production call sites use the
    ///     default, which is the real notice log.
    @MainActor
    static func run(
        timeout: TimeInterval = MCPServerLimits.perRequestTimeout,
        onTimeoutExceeded: @escaping () -> Void = {
            MCPLog.transport.notice("Request exceeded \(MCPServerLimits.perRequestTimeout, privacy: .public)s timeout budget.")
        },
        _ operation: @escaping @MainActor () async -> MCPHTTPResponse
    ) async -> MCPHTTPResponse {
        await withTaskGroup(of: MCPHTTPResponse.self) { group in
            group.addTask { await operation() }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    // Cancelled by `group.cancelAll()` below because `operation()` already won the
                    // race — this task's return value is never consumed (only the first completion
                    // is read via `group.next()`), but `withTaskGroup` still awaits every child
                    // before returning, so this task keeps running to here regardless. A bare
                    // `try?` swallowed this and fell through to the log + 408 unconditionally,
                    // making every request log a false "exceeded timeout budget" notice.
                    return MCPHTTPResponse.response(status: 0)
                }
                onTimeoutExceeded()
                return MCPHTTPResponse.response(
                    status: 408,
                    headers: [:],
                    body: Data("Request Timeout".utf8)
                )
            }
            let first = await group.next() ?? MCPHTTPResponse.response(
                status: 500,
                headers: [:],
                body: Data("Internal Error".utf8)
            )
            group.cancelAll()
            return first
        }
    }
}

/// Production loopback MCP Streamable HTTP transport using SwiftNIO's HTTP/1 pipeline.
///
/// Concurrency: request handling hops to the main-actor ``MCPProtocolService``. HTTP parsing,
/// framing validation, and bounded body aggregation stay on the channel event loop. GET listen/SSE
/// streams bypass the per-request timeout wrapper and remain open until closed by the client,
/// server stop, or idle timeout (kept alive by hub heartbeats).
final class MCPNIOHTTPTransport: @unchecked Sendable {
    enum TransportError: Error, Equatable {
        case alreadyRunning
        case notRunning
        case bindFailed(String)
    }

    private let group: MultiThreadedEventLoopGroup
    private let protocolService: MCPProtocolService
    private let idleTimeout: TimeInterval
    private var serverChannel: Channel?
    private let state = ConnectionState()

    init(
        protocolService: MCPProtocolService,
        group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
        idleTimeout: TimeInterval = 30
    ) {
        self.protocolService = protocolService
        self.group = group
        self.idleTimeout = idleTimeout
    }

    var isRunning: Bool { serverChannel != nil }
    var boundPort: UInt16? {
        guard let port = serverChannel?.localAddress?.port else { return nil }
        return UInt16(exactly: port)
    }

    func start(port: UInt16 = NetworkConstants.mcpDefaultPort) async throws {
        guard serverChannel == nil else { throw TransportError.alreadyRunning }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandlers([
                        IdleStateHandler(allTimeout: .seconds(Int64(self.idleTimeout))),
                        MCPHTTPChannelHandler(
                            protocolService: self.protocolService,
                            connectionState: self.state
                        )
                    ])
                }
            }

        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get()
            serverChannel = channel
            MCPLog.lifecycle.info("MCP transport bound on 127.0.0.1:\(port, privacy: .public).")
        } catch {
            try? await group.shutdownGracefully()
            MCPLog.lifecycle.error("MCP transport failed to bind on port \(port, privacy: .public): \(String(describing: error), privacy: .public)")
            throw TransportError.bindFailed(String(describing: error))
        }
    }

    func stop() async {
        try? await serverChannel?.close()
        serverChannel = nil
        MCPLog.lifecycle.info("MCP transport stopped.")
    }

    func shutdown(waitForInFlight: Bool = false, protocolService: MCPProtocolService? = nil) async {
        state.beginShutdown()
        await stop()
        if waitForInFlight, let protocolService {
            let deadline = Date().addingTimeInterval(MCPServerLimits.gracefulStopDeadline)
            while Date() < deadline {
                let inFlight = await MainActor.run { protocolService.inFlightHTTPRequestCount }
                // Protocol work ends before its response reaches the channel event loop.
                // Keep that loop alive until the response has flushed and closed its connection.
                if inFlight == 0, state.requestCount == 0 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        try? await group.shutdownGracefully()
    }
}

private final class ConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequestConnections = 0
    private var activeListenConnections = 0
    private var acceptingRequests = true

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestConnections
    }

    func beginShutdown() {
        lock.lock()
        defer { lock.unlock() }
        acceptingRequests = false
    }

    func tryBeginRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingRequests, activeRequestConnections < MCPServerLimits.concurrentRequestConnections else { return false }
        activeRequestConnections += 1
        return true
    }

    func tryBeginListen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingRequests, activeListenConnections < MCPServerLimits.maxConcurrentListenStreams else { return false }
        activeListenConnections += 1
        return true
    }

    func endRequest() {
        lock.lock()
        defer { lock.unlock() }
        activeRequestConnections = max(0, activeRequestConnections - 1)
    }

    func endListen() {
        lock.lock()
        defer { lock.unlock() }
        activeListenConnections = max(0, activeListenConnections - 1)
    }
}

private final class MCPHTTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum ConnectionKind {
        case none
        case request
        case listen
    }

    private let protocolService: MCPProtocolService
    private let connectionState: ConnectionState
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var tracked = false
    private var isResponding = false
    private var isDraining = false
    private var drainDeadline: Scheduled<Void>?
    private var connectionKind: ConnectionKind = .none
    private var sseSessionKey: MCPLogicalSessionKey?
    private var sseWriter: MCPSSEWriter?

    init(protocolService: MCPProtocolService, connectionState: ConnectionState) {
        self.protocolService = protocolService
        self.connectionState = connectionState
    }

    func channelActive(context: ChannelHandlerContext) {
        tracked = true
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        drainDeadline?.cancel()
        drainDeadline = nil
        switch connectionKind {
        case .request:
            connectionState.endRequest()
        case .listen:
            connectionState.endListen()
            if let sseSessionKey, let sseWriter {
                let key = sseSessionKey
                let writer = sseWriter
                Task { @MainActor in
                    self.protocolService.unregisterSSEWriter(key: key, writer: writer)
                }
            }
        case .none:
            break
        }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isResponding else {
            // A request rejected before its body finished arriving (e.g. oversized Content-Length)
            // is still draining the client's in-flight bytes — see `beginDraining`. Once the client
            // actually finishes sending, close cleanly instead of waiting for the safety-net timer.
            if isDraining, case .end = unwrapInboundIn(data) {
                finishDraining(context: context)
            }
            return
        }
        switch unwrapInboundIn(data) {
        case .head(let head):
            receiveHead(head, context: context)
        case .body(var buffer):
            receiveBody(&buffer, context: context)
        case .end:
            finishRequest(context: context)
        }
    }

    private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard requestHead == nil else {
            reject(status: 400, message: "Multiple requests are not supported.", context: context)
            return
        }
        guard NIOHTTPRequestHeaderSize.estimatedBytes(head) <= MCPNetworkConstants.maxHeaderBytes else {
            reject(status: 431, message: "Request header fields too large", context: context)
            return
        }

        let contentLengths = head.headers["content-length"]
        if contentLengths.count > 1 {
            reject(status: 400, message: "Invalid Content-Length", context: context)
            return
        }
        let transferEncodings = head.headers["transfer-encoding"]
        if transferEncodings.count > 1 {
            reject(status: 400, message: "Invalid Transfer-Encoding", context: context)
            return
        }
        let isChunked = transferEncodings.first?.localizedCaseInsensitiveContains("chunked") == true
        if isChunked, !contentLengths.isEmpty {
            reject(status: 400, message: "Invalid message framing", context: context)
            return
        }
        if let rawLength = contentLengths.first {
            guard let contentLength = Int(rawLength),
                  contentLength >= 0 else {
                reject(status: 400, message: "Invalid Content-Length", context: context)
                return
            }
            guard contentLength <= MCPNetworkConstants.maxRequestBodyBytes else {
                reject(status: 413, message: "Payload Too Large", context: context)
                return
            }
            requestBody.reserveCapacity(contentLength)
        }
        requestHead = head
    }

    private func receiveBody(_ buffer: inout ByteBuffer, context: ChannelHandlerContext) {
        guard requestHead != nil else {
            reject(status: 400, message: "Request body arrived before headers.", context: context)
            return
        }
        let incomingBytes = buffer.readableBytes
        guard requestBody.count <= MCPNetworkConstants.maxRequestBodyBytes - incomingBytes else {
            reject(status: 413, message: "Payload Too Large", context: context)
            return
        }
        if let bytes = buffer.readBytes(length: incomingBytes) {
            requestBody.append(contentsOf: bytes)
        }
    }

    private func finishRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else {
            reject(status: 400, message: "Missing request headers.", context: context)
            return
        }
        isResponding = true
        let headers = Self.normalizedHeaders(head.headers)
        let method = head.method.rawValue
        let path = head.uri
        let body = requestBody
        let channel = context.channel

        if Self.isSSEListenRequest(method: method, path: path, headers: headers) {
            handleSSEListen(context: context, headers: headers, channel: channel)
            return
        }

        guard connectionState.tryBeginRequest() else {
            MCPLog.transport.notice("Rejected connection: request-connection limit reached.")
            reject(
                status: 503,
                message: "Too many connections",
                context: context,
                releaseRequestSlot: false
            )
            return
        }
        connectionKind = .request

        Task { @MainActor in
            let response = await MCPRequestTimeoutRace.run {
                await self.protocolService.handleHTTPRequest(
                    method: method,
                    path: path,
                    headers: headers,
                    body: body,
                    isConnected: { channel.isActive }
                )
            }
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                channel.pipeline.context(handlerType: MCPHTTPChannelHandler.self).whenSuccess { handlerContext in
                    self.writeResponse(context: handlerContext, response: response)
                }
            }
        }
    }

    private func handleSSEListen(context: ChannelHandlerContext, headers: [String: String], channel: Channel) {
        Task { @MainActor in
            let result = await self.protocolService.handleSSEListenRequest(headers: headers)
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                channel.pipeline.context(handlerType: MCPHTTPChannelHandler.self).whenSuccess { handlerContext in
                    switch result {
                    case .accepted(let key):
                        guard self.connectionState.tryBeginListen() else {
                            self.writeResponse(
                                context: handlerContext,
                                response: MCPHTTPResponse.response(
                                    status: 503,
                                    headers: [:],
                                    body: Data("Too many listen streams".utf8)
                                )
                            )
                            return
                        }
                        self.connectionKind = .listen
                        self.sseSessionKey = key
                        self.writeSSEHead(context: handlerContext)
                        let writer = MCPSSEWriter(channel: channel, onClose: {})
                        self.sseWriter = writer
                        Task { @MainActor in
                            // Registration hops to the MainActor asynchronously, so a peer that
                            // disconnects in the gap between scheduling this Task and it actually
                            // running could otherwise leave a phantom writer registered for an
                            // already-dead channel that no future `channelInactive` will fire for
                            // (unstructured Tasks created from different call sites have no
                            // guaranteed ordering). Re-check liveness right before registering.
                            guard channel.isActive else { return }
                            self.protocolService.registerSSEWriter(key: key, writer: writer)
                        }
                    case .rejected(let response):
                        self.writeResponse(context: handlerContext, response: response)
                    }
                }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            MCPLog.transport.debug("Closing idle connection after inactivity.")
            if connectionKind == .listen, let sseSessionKey, let sseWriter {
                let key = sseSessionKey
                let writer = sseWriter
                Task { @MainActor in
                    self.protocolService.unregisterSSEWriter(key: key, writer: writer)
                }
            }
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        MCPLog.transport.notice("HTTP pipeline error, closing connection: \(String(describing: error), privacy: .public)")
        isResponding = true
        context.eventLoop.scheduleTask(in: .milliseconds(10)) {
            context.close(promise: nil)
        }
    }

    private func reject(status: Int, message: String, context: ChannelHandlerContext, releaseRequestSlot: Bool = true) {
        guard !isResponding else { return }
        isResponding = true
        MCPLog.transport.notice("Rejected request (\(status, privacy: .public)): \(message, privacy: .public)")
        if releaseRequestSlot, connectionKind == .request {
            connectionState.endRequest()
            connectionKind = .none
        }
        // A rejection fired from `receiveHead`/`receiveBody` happens *before* the client has
        // finished sending its body (that's the whole point — e.g. an oversized Content-Length is
        // rejected without waiting for the full upload). Closing immediately after writing the
        // response races the client still writing to the same socket: if the kernel still has
        // unread inbound bytes for this connection when the server closes, POSIX sends an RST
        // instead of a clean FIN, which the client's HTTP stack surfaces as a network error/timeout
        // instead of delivering the response we already sent (observed as flaky
        // NSURLErrorNetworkConnectionLost / NSURLErrorTimedOut). Draining until the client's `.end`
        // (or a safety-net deadline, in case it never finishes) avoids the race.
        writeResponse(
            context: context,
            response: MCPHTTPResponse.response(
                status: status,
                headers: [:],
                body: Data(message.utf8)
            ),
            closeAfterWrite: false
        )
        beginDraining(context: context)
    }

    private func beginDraining(context: ChannelHandlerContext) {
        isDraining = true
        drainDeadline = context.eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in
            self?.finishDraining(context: context)
        }
    }

    private func finishDraining(context: ChannelHandlerContext) {
        guard isDraining else { return }
        isDraining = false
        drainDeadline?.cancel()
        drainDeadline = nil
        context.close(promise: nil)
    }

    private func writeResponse(
        context: ChannelHandlerContext,
        response: MCPHTTPResponse,
        closeAfterWrite: Bool = true
    ) {
        response.write(to: context, closeAfterWrite: closeAfterWrite)
    }

    private func writeSSEHead(context: ChannelHandlerContext) {
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive"
            ]
        )
        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
    }

    private static func isSSEListenRequest(method: String, path: String, headers: [String: String]) -> Bool {
        guard method == "GET", path == MCPNetworkConstants.endpointPath else { return false }
        return headers["accept"]?.lowercased().contains("text/event-stream") == true
    }

    private static func normalizedHeaders(_ headers: HTTPHeaders) -> [String: String] {
        var normalized: [String: String] = [:]
        for header in headers {
            let name = header.name.lowercased()
            if let existing = normalized[name] {
                normalized[name] = "\(existing), \(header.value)"
            } else {
                normalized[name] = header.value
            }
        }
        return normalized
    }
}
