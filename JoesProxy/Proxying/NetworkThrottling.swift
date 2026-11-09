import Foundation
import NIOCore

enum NetworkThrottlePresetID {
    static let modem56k = "56k-modem"
    static let isdn = "isdn"
    static let t1 = "t1"
    static let mobile3G = "mobile-3g"
    static let mobileLTE = "mobile-lte"
    static let custom = "custom"
}

struct NetworkThrottlePreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var downstreamKbps: Int
    var upstreamKbps: Int
    var latencyMs: Int
    var isEditable: Bool

    var isValid: Bool {
        downstreamKbps > 0 && upstreamKbps > 0 && latencyMs >= 0
    }
}

struct NetworkThrottleConfiguration: Codable, Equatable, Sendable {
    enum Direction: Sendable {
        case downstream
        case upstream
    }

    var isEnabled: Bool
    var selectedPresetID: String
    var presets: [NetworkThrottlePreset]
    var mcpOrigin: MCPObjectOrigin?
    var mcpProvenance: MCPProvenance?
    var mcpTargetRevision: MCPTargetRevision?

    static let defaults = NetworkThrottleConfiguration(
        isEnabled: false,
        selectedPresetID: NetworkThrottlePresetID.mobile3G,
        presets: defaultPresets,
        mcpOrigin: nil,
        mcpProvenance: nil,
        mcpTargetRevision: nil
    )

    static let defaultPresets: [NetworkThrottlePreset] = [
        NetworkThrottlePreset(
            id: NetworkThrottlePresetID.modem56k,
            name: "56k Modem",
            downstreamKbps: 56,
            upstreamKbps: 33,
            latencyMs: 150,
            isEditable: true
        ),
        NetworkThrottlePreset(
            id: NetworkThrottlePresetID.isdn,
            name: "ISDN",
            downstreamKbps: 128,
            upstreamKbps: 128,
            latencyMs: 80,
            isEditable: true
        ),
        NetworkThrottlePreset(
            id: NetworkThrottlePresetID.t1,
            name: "T1",
            downstreamKbps: 1_544,
            upstreamKbps: 1_544,
            latencyMs: 20,
            isEditable: true
        ),
        NetworkThrottlePreset(
            id: NetworkThrottlePresetID.mobile3G,
            name: "Mobile 3G",
            downstreamKbps: 1_600,
            upstreamKbps: 768,
            latencyMs: 150,
            isEditable: true
        ),
        NetworkThrottlePreset(
            id: NetworkThrottlePresetID.mobileLTE,
            name: "Mobile LTE",
            downstreamKbps: 12_000,
            upstreamKbps: 5_000,
            latencyMs: 50,
            isEditable: true
        ),
        NetworkThrottlePreset(
            id: NetworkThrottlePresetID.custom,
            name: "Custom",
            downstreamKbps: 750,
            upstreamKbps: 250,
            latencyMs: 100,
            isEditable: true
        )
    ]

    var selectedPreset: NetworkThrottlePreset? {
        presets.first { $0.id == selectedPresetID }
    }

    func effectivePreset() -> NetworkThrottlePreset? {
        guard isEnabled, let preset = selectedPreset, preset.isValid else {
            return nil
        }
        return preset
    }

    func kbps(for direction: Direction) -> Int? {
        guard let preset = effectivePreset() else {
            return nil
        }

        switch direction {
        case .downstream:
            return preset.downstreamKbps
        case .upstream:
            return preset.upstreamKbps
        }
    }
}

final class NetworkThrottleWriter {
    typealias ConfigurationProvider = () -> NetworkThrottleConfiguration

    private enum Constants {
        static let maxChunkSize = 16 * 1_024
        static let bitsPerByte = 8.0
        static let millisecondsPerSecond = 1_000.0
        static let nanosecondsPerSecond = 1_000_000_000.0
    }

    private let direction: NetworkThrottleConfiguration.Direction
    private let configurationProvider: ConfigurationProvider
    private let relayBudget: RelayBacklogBudget
    private var tailFuture: EventLoopFuture<Void>?
    private var pendingRelayWrites = 0
    private(set) var pendingRelayBytes = 0
    private(set) var peakRelayBytes = 0
    private var readRegistrations: [ObjectIdentifier: UUID] = [:]
    private let admissionLock = NSLock()
    private var sourceAdmissions: [ObjectIdentifier: Int] = [:]
    var pendingRelayAdmissions: Int { admissionLock.withLock { sourceAdmissions.values.reduce(0, +) } }

    /// Call on the source loop. Admit before crossing loops; destination owns write scheduling,
    /// while locked per-source counts include writes not yet visible to that scheduler.
    func relay(_ buffer: ByteBuffer, to destination: Channel, readingFrom source: Channel,
               diagnostics: RequestTransportDiagnostics? = nil) -> EventLoopFuture<Void> {
        source.eventLoop.preconditionInEventLoop()
        let sourceID = ObjectIdentifier(source)
        admissionLock.withLock { sourceAdmissions[sourceID, default: 0] += 1 }
        // Account before a closure carrying bytes is dispatched to another event loop.
        let cost = buffer.readableBytes
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        diagnostics?.submitted(bytes: cost, now: submittedAt)
        relayBudget.adjust(bytes: cost, operations: 1)
        let delivered = source.setOption(ChannelOptions.autoRead, value: false).flatMap {
            diagnostics?.readPaused(aggregatePressure: self.relayBudget.snapshot.paused, socketBackpressure: !destination.isWritable)
            let forward = {
                diagnostics?.dispatched(submittedAt: submittedAt,
                    throttled: self.configurationProvider().effectivePreset() != nil)
                let key = ObjectIdentifier(source)
                if self.readRegistrations[key] == nil {
                    let id = self.relayBudget.register { [weak self, weak source, weak destination] _ in
                        guard let self, let source, let destination else { return }
                        self.reconcileAggregatePressure(from: source, to: destination, diagnostics: diagnostics)
                    }
                    self.readRegistrations[key] = id
                    source.closeFuture.whenComplete { [weak self, relayBudget = self.relayBudget] _ in
                        diagnostics?.readsResumedOrClosed()
                        relayBudget.unregister(id)
                        destination.eventLoop.execute { self?.readRegistrations[key] = nil }
                    }
                }
                self.pendingRelayWrites += 1
                self.pendingRelayBytes += buffer.readableBytes
                self.peakRelayBytes = max(self.peakRelayBytes, self.pendingRelayBytes)
                let future = self.writeReserved(buffer, to: destination)
                future.whenComplete { result in
                    self.pendingRelayWrites -= 1
                    self.pendingRelayBytes -= buffer.readableBytes
                    switch result {
                    case .success:
                        break
                    case .failure:
                        source.close(promise: nil)
                        destination.close(promise: nil)
                    }
                }
                return future
            }
            // Do not add a scheduling turn to immediate same-loop header/body delivery.
            if destination.eventLoop.inEventLoop { return forward() }
            return destination.eventLoop.flatSubmit(forward)
        }
        delivered.whenComplete { result in
            if case .success = result { diagnostics?.completed(bytes: cost, succeeded: true) }
            else { diagnostics?.completed(bytes: cost, succeeded: false) }
            self.admissionLock.withLock {
                let remaining = self.sourceAdmissions[sourceID, default: 0] - 1
                if remaining == 0 { self.sourceAdmissions.removeValue(forKey: sourceID) }
                else { self.sourceAdmissions[sourceID] = remaining }
            }
            self.relayBudget.adjust(bytes: -cost, operations: -1)
            if case .success = result { self.resumeReadsIfDrained(from: source, to: destination, diagnostics: diagnostics) }
        }
        return delivered
    }

    /// Budget callbacks can arrive out of order on unrelated loops. Read current pressure only
    /// on the source loop, immediately before changing that channel's read policy.
    func reconcileAggregatePressure(from source: Channel, to destination: Channel, diagnostics: RequestTransportDiagnostics? = nil) {
        source.eventLoop.execute {
            guard source.isActive else { return }
            if self.relayBudget.snapshot.paused {
                source.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
                    diagnostics?.readPaused(aggregatePressure: true, socketBackpressure: !destination.isWritable)
                }
            } else {
                self.resumeReadsIfDrained(from: source, to: destination, diagnostics: diagnostics)
            }
        }
    }

    func resumeReadsIfDrained(from source: Channel, to destination: Channel, diagnostics: RequestTransportDiagnostics? = nil) {
        destination.eventLoop.execute {
            guard self.pendingRelayWrites == 0, source.isActive, destination.isActive,
                  destination.isWritable, !self.relayBudget.snapshot.paused else { return }
            source.eventLoop.execute {
                guard source.isActive, destination.isActive, destination.isWritable,
                      self.admissionLock.withLock({ self.sourceAdmissions[ObjectIdentifier(source)] == nil }),
                      !self.relayBudget.snapshot.paused else { return }
                source.setOption(ChannelOptions.autoRead, value: true).whenSuccess {
                    diagnostics?.readsResumedOrClosed()
                    source.read()
                }
            }
        }
    }

    private func registerTail(_ future: EventLoopFuture<Void>) {
        let recovered = future.recover { _ in }
        tailFuture = recovered
        recovered.whenComplete { [weak self] _ in
            if self?.tailFuture === recovered { self?.tailFuture = nil }
        }
    }

    init(
        direction: NetworkThrottleConfiguration.Direction,
        configurationProvider: @escaping ConfigurationProvider,
        relayBudget: RelayBacklogBudget = .shared
    ) {
        self.direction = direction
        self.configurationProvider = configurationProvider
        self.relayBudget = relayBudget
    }

    func waitUntilDrained() -> EventLoopFuture<Void>? {
        tailFuture
    }

    func writeAndFlush(_ buffer: ByteBuffer, to channel: Channel) -> EventLoopFuture<Void> {
        let cost = buffer.readableBytes
        relayBudget.adjust(bytes: cost, operations: 1)
        let future = writeReserved(buffer, to: channel)
        future.whenComplete { _ in self.relayBudget.adjust(bytes: -cost, operations: -1) }
        return future
    }

    private func writeReserved(_ buffer: ByteBuffer, to channel: Channel) -> EventLoopFuture<Void> {
        guard channel.eventLoop.inEventLoop else {
            return channel.eventLoop.flatSubmit { self.writeReserved(buffer, to: channel) }
        }
        let eventLoop = channel.eventLoop
        let startFuture = tailFuture ?? eventLoop.makeSucceededFuture(())
        let configuration = configurationProvider()

        guard let preset = configuration.effectivePreset(),
              let kbps = configuration.kbps(for: direction),
              kbps > 0 else {
            if let tailFuture {
                let writeFuture = tailFuture.flatMap {
                    channel.writeAndFlush(buffer)
                }
                self.registerTail(writeFuture)
                return writeFuture
            } else {
                return channel.writeAndFlush(buffer)
            }
        }

        guard buffer.readableBytes > 0 else { return startFuture }
        let chain = startFuture.flatMap {
            ThrottledBufferPump(buffer: buffer, channel: channel, kbps: kbps)
                .start(latencyMs: preset.latencyMs)
        }

        registerTail(chain)
        return chain
    }

    static func plannedChunkSizes(byteCount: Int, maxChunkSize: Int = Constants.maxChunkSize) -> [Int] {
        guard byteCount > 0, maxChunkSize > 0 else {
            return []
        }

        var remaining = byteCount
        var chunks: [Int] = []
        while remaining > 0 {
            let size = min(maxChunkSize, remaining)
            chunks.append(size)
            remaining -= size
        }
        return chunks
    }

    static func delayAfterChunk(byteCount: Int, kbps: Int) -> TimeAmount {
        guard byteCount > 0, kbps > 0 else {
            return .nanoseconds(0)
        }

        let bytesPerSecond = (Double(kbps) * Constants.millisecondsPerSecond) / Constants.bitsPerByte
        let seconds = Double(byteCount) / bytesPerSecond
        let nanoseconds = Int64(ceil(seconds * Constants.nanosecondsPerSecond))
        return .nanoseconds(max(0, nanoseconds))
    }

    private static func chunks(from buffer: ByteBuffer) -> [ByteBuffer] {
        plannedChunkSizes(byteCount: buffer.readableBytes).reduce(
            into: (offset: buffer.readerIndex, chunks: [ByteBuffer]())
        ) { state, size in
            if let chunk = buffer.getSlice(at: state.offset, length: size) {
                state.chunks.append(chunk)
            }
            state.offset += size
        }.chunks
    }
}
