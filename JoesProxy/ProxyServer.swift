import Foundation
import NIOCore
import NIOPosix
import os

// Used only at NIO callback boundaries where the closure must be `@Sendable`
// but the referenced dependency is intentionally loop-confined and immutable
// for the lifetime of the callback. See `memlog/Research/NIO-Sendable-And-UncheckedSendableBox.md`.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

public final class ProxyServer {
    public static let shared = ProxyServer()

    private let logger = Logger(subsystem: "com.joesproxyapp", category: "ProxyServer")
    private let requestParser: HTTPRequestParser
    private let responseParser: HTTPResponseParser
    private let sessionRecorder: ProxySessionRecorder?
    private let responseOverrideStore: ResponseOverrideStore?
    private let bookmarkResponseInterceptStore: BookmarkResponseInterceptStore?
    private let fixtureOriginRegistry: HLSFixtureOriginRegistry?
    private let hlsSubstitutionRouteStore: HLSSubstitutionRouteStore?
    private let openAPIMockRouteStore: OpenAPIMockRouteStore?
    private let httpsProxyMode: HTTPSProxyMode
    private let configuration: (any AppConfiguration)?
    private let certificateAuthority: (any CertificateAuthorityProviding)?
    private let transportDiagnostics: CaptureTransportDiagnostics?
    private let upstreamConnectorConfiguration: HTTPUpstreamConnectorConfiguration
    private let uploadSpoolService: UploadSpoolService?
    private let liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var uploadForwardingLifecycle: UploadForwardingLifecycle?
    private var listenerReservation: ReservedListenerRegistry.ReservationToken?

    public var port: UInt16
    public let bindHost: String

    public var isRunning: Bool {
        serverChannel != nil
    }

    init(
        port: UInt16 = NetworkConstants.defaultPort,
        bindHost: String = NetworkConstants.defaultBindHost,
        requestParser: HTTPRequestParser = HTTPRequestParser(),
        responseParser: HTTPResponseParser = HTTPResponseParser(),
        httpsProxyMode: HTTPSProxyMode = .passThrough,
        configuration: (any AppConfiguration)? = nil,
        certificateAuthority: (any CertificateAuthorityProviding)? = nil,
        sessionRecorder: ProxySessionRecorder? = nil,
        responseOverrideStore: ResponseOverrideStore? = nil,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore? = nil,
        fixtureOriginRegistry: HLSFixtureOriginRegistry? = nil,
        hlsSubstitutionRouteStore: HLSSubstitutionRouteStore? = nil,
        openAPIMockRouteStore: OpenAPIMockRouteStore? = nil,
        transportDiagnostics: CaptureTransportDiagnostics? = nil,
        upstreamConnectorConfiguration: HTTPUpstreamConnectorConfiguration = HTTPUpstreamConnectorConfiguration(),
        uploadSpoolService: UploadSpoolService? = nil,
        liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor = LiveCollectionTransformationExecutor()
    ) {
        self.port = port
        self.uploadSpoolService = uploadSpoolService
        if let uploadSpoolService { transportDiagnostics?.observeUploads(uploadSpoolService) }
        self.bindHost = bindHost
        self.requestParser = requestParser
        self.responseParser = responseParser
        self.httpsProxyMode = httpsProxyMode
        self.configuration = configuration
        self.certificateAuthority = certificateAuthority
        self.sessionRecorder = sessionRecorder
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkResponseInterceptStore = bookmarkResponseInterceptStore
        self.fixtureOriginRegistry = fixtureOriginRegistry
        self.hlsSubstitutionRouteStore = hlsSubstitutionRouteStore
        self.openAPIMockRouteStore = openAPIMockRouteStore
        self.transportDiagnostics = transportDiagnostics
        self.upstreamConnectorConfiguration = upstreamConnectorConfiguration
        self.liveCollectionTransformationExecutor = liveCollectionTransformationExecutor
    }

    public func start() async throws {
        guard !isRunning else {
            logger.warning("Proxy server is already running")
            return
        }

        do {
            do { try await uploadSpoolService?.prepare() }
            catch { logger.error("Upload storage unavailable; affected uploads will fail explicitly: \(error.localizedDescription, privacy: .public)") }
            await sessionRecorder?.startCaptureRun()
            try await bindServer()
            logger.info("Proxy server started successfully on port \(self.port)")
        } catch {
            await sessionRecorder?.finishCaptureRun()
            logger.error("Failed to start proxy server on port \(self.port): \(error.localizedDescription)")
            throw ProxyError.startFailed(reason: startFailureMessage(for: error))
        }
    }

    public func stop() async {
        uploadSpoolService?.stopAdmission()
        sessionRecorder?.admission.setAccepting(false)
        if let serverChannel {
            try? await serverChannel.close().get()
        }

        serverChannel = nil
        ReservedListenerRegistry.shared.release(listenerReservation)
        listenerReservation = nil

        await uploadForwardingLifecycle?.stopAndDrain()
        uploadForwardingLifecycle = nil

        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }

        self.eventLoopGroup = nil
        if let uploadSpoolService, !(await uploadSpoolService.drain()) {
            logger.error("Upload spool cleanup did not complete; recovery is required")
        }
        await sessionRecorder?.finishCaptureRun()
        logger.info("Proxy server stopped")
    }

    private func bindServer() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let uploadForwardingLifecycle = UploadForwardingLifecycle()
        let logger = self.logger
        let requestParser = self.requestParser
        let responseParser = self.responseParser
        let httpsProxyMode = self.httpsProxyMode
        let configuration = UncheckedSendableBox(value: self.configuration)
        let certificateAuthority = UncheckedSendableBox(value: self.certificateAuthority)
        let sessionRecorder = self.sessionRecorder
        let responseOverrideStore = self.responseOverrideStore
        let bookmarkResponseInterceptStore = self.bookmarkResponseInterceptStore
        let fixtureOriginRegistry = self.fixtureOriginRegistry
        let hlsSubstitutionRouteStore = self.hlsSubstitutionRouteStore
        let openAPIMockRouteStore = self.openAPIMockRouteStore
        let upstreamConnectorConfiguration = self.upstreamConnectorConfiguration
        let transportDiagnostics = self.transportDiagnostics
        let uploadSpoolService = self.uploadSpoolService
        let liveCollectionTransformationExecutor = self.liveCollectionTransformationExecutor

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 32 * 1024, high: 128 * 1024))
            .childChannelInitializer { channel in
                let upstreamConnector = HTTPUpstreamConnector(
                    group: group,
                    responseParser: responseParser,
                    configuration: upstreamConnectorConfiguration,
                    appConfiguration: configuration.value,
                    throttleConfigurationProvider: {
                        configuration.value?.networkThrottleConfiguration ?? .defaults
                    },
                    uploadForwardingLifecycle: uploadForwardingLifecycle,
                    liveCollectionTransformationExecutor: liveCollectionTransformationExecutor
                )
                let remoteAddress = channel.remoteAddress?.description ?? "unknown"
                let localAddress = channel.localAddress?.description ?? "unknown"
                logger.info(
                    "Accepted proxy client connection remote=\(remoteAddress, privacy: .public) local=\(localAddress, privacy: .public)"
                )
                return channel.pipeline.addHandler(
                    ProxyConnectionHandler(
                        requestParser: requestParser,
                        responseParser: responseParser,
                        upstreamConnector: upstreamConnector,
                        httpsProxyMode: httpsProxyMode,
                        configuration: configuration.value,
                        certificateAuthority: certificateAuthority.value,
                        sessionRecorder: sessionRecorder,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        fixtureOriginRegistry: fixtureOriginRegistry,
                        hlsSubstitutionRouteStore: hlsSubstitutionRouteStore,
                        openAPIMockRouteStore: openAPIMockRouteStore,
                        throttleConfigurationProvider: {
                            configuration.value?.networkThrottleConfiguration ?? .defaults
                        },
                        eventLoopGroup: group,
                        transportDiagnostics: transportDiagnostics,
                        uploadSpoolService: uploadSpoolService,
                        uploadForwardingLifecycle: uploadForwardingLifecycle
                    )
                )
            }

        if port > 0 {
            self.listenerReservation = ReservedListenerRegistry.shared.reserve(
                owner: "ProxyServer",
                port: port,
                boundHost: bindHost == "0.0.0.0" || bindHost == "::" ? nil : bindHost
            )
        }

        do {
            logger.info("Binding proxy server to \(self.bindHost, privacy: .public):\(self.port)")
            let channel = try await bootstrap.bind(host: self.bindHost, port: Int(port)).get()
            self.eventLoopGroup = group
            self.uploadForwardingLifecycle = uploadForwardingLifecycle
            self.serverChannel = channel
            let localAddressDescription = channel.localAddress?.description ?? "unknown"
            logger.info("Proxy server listening on \(localAddressDescription, privacy: .public)")
            if let localAddress = channel.localAddress,
               let boundPort = localAddress.port.flatMap(UInt16.init(exactly:)) {
                self.port = boundPort
                if self.listenerReservation == nil {
                    self.listenerReservation = ReservedListenerRegistry.shared.reserve(
                        owner: "ProxyServer",
                        port: boundPort,
                        boundHost: bindHost == "0.0.0.0" || bindHost == "::" ? nil : bindHost
                    )
                }
            }
        } catch {
            ReservedListenerRegistry.shared.release(self.listenerReservation)
            self.listenerReservation = nil
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func startFailureMessage(for error: Error) -> String {
        let presentation = NetworkFailureClassifier.presentation(for: error)
        if presentation.bucket == .localProxyStart {
            return presentation.userFacingMessage
        }

        return "JoesProxy could not start on port \(port). \(presentation.userFacingMessage)"
    }
}
