import Foundation

/// Test-only SDK facade. Used in unit tests and previews; the app uses TVOSLiveProxySDKClient.
struct TVOSMockProxySDKClient: TVOSProxySDKFacading {
    let discoveryService: any TVOSProxyDiscoveryServicing
    let transport: any TVOSProxyTransporting
    let setupProbe: any TVOSProxySetupProbing
    let annotationSender: any TVOSAnnotationSending

    init(
        discoveryService: any TVOSProxyDiscoveryServicing = TVOSMockDiscoveryService(),
        transport: any TVOSProxyTransporting = TVOSFixtureReplayProxyTransport(),
        setupProbe: any TVOSProxySetupProbing = TVOSReachabilitySetupProbe(),
        annotationSender: any TVOSAnnotationSending = TVOSRecordingAnnotationSender()
    ) {
        self.discoveryService = discoveryService
        self.transport = transport
        self.setupProbe = setupProbe
        self.annotationSender = annotationSender
    }
}

/// Deterministic discovery for previews, UI tests, and early scaffold work.
struct TVOSMockDiscoveryService: TVOSProxyDiscoveryServicing {
    let proxies: [TVOSDiscoveredProxy]

    init(proxies: [TVOSDiscoveredProxy] = [.fixture]) {
        self.proxies = proxies
    }

    func discover() async -> [TVOSDiscoveredProxy] {
        proxies
    }
}

/// Pre-loaded event sequence for use in tests and previews.
struct TVOSFixtureReplayProxyTransport: TVOSProxyTransporting {
    private let fixtureData: [Data]

    init(fixtureData: [Data] = TVOSFixtureReplayProxyTransport.defaultFixtureData) {
        self.fixtureData = fixtureData
    }

    init(fixtureURLs: [URL]) throws {
        self.fixtureData = try fixtureURLs.map { try Data(contentsOf: $0) }
    }

    func connect(to proxy: TVOSDiscoveredProxy, pairingToken: String?) async -> TVOSProxyConnectionState {
        .connected(proxy)
    }

    func disconnect() async {}

    func collectedEvents() async -> [TVOSSDKMessageHeader] {
        fixtureData.compactMap { data in
            try? TVOSSDKEventJSONCodec.makeDecoder().decode(TVOSSDKMessageHeader.self, from: data)
        }
    }

    func collectedNetworkEvents() async -> [TVOSObservedNetworkEvent] {
        fixtureData.compactMap(TVOSNetworkEventObservation.parseEnvelopeJSON)
    }

    static let defaultFixtureData: [Data] = [
        makeEnvelopeData(
            type: "handshakeAck",
            id: "00000000-0000-0000-0000-000000000102",
            sentAt: "2026-06-28T17:00:00.125Z",
            payload: [
                "accepted": true,
                "rejectReason": NSNull(),
                "serverTimestamp": "2026-06-28T17:00:00.125Z",
                "clockOffsetMs": 0,
                "selectedSchemaVersion": 1,
                "supportedSchemaVersions": [1]
            ]
        ),
        makeEnvelopeData(
            type: "annotationEvent",
            id: "00000000-0000-0000-0000-000000000301",
            sentAt: "2026-06-28T17:00:02.500Z",
            payload: [
                "id": "00000000-0000-0000-0000-000000000302",
                "scopeID": NSNull(),
                "label": "Fixture annotation",
                "kind": "feature",
                "lifecycle": "instant",
                "metadata": [:] as [String: String],
                "deviceTimestamp": "2026-06-28T17:00:02.500Z"
            ]
        )
    ]

    private static func makeEnvelopeData(
        type: String,
        id: String,
        sentAt: String,
        payload: [String: Any]
    ) -> Data {
        let envelope: [String: Any] = [
            "type": type,
            "version": 1,
            "id": id,
            "sentAt": sentAt,
            "payload": payload
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
}

/// Records annotations locally until live SDK annotation transport exists.
actor TVOSRecordingAnnotationSender: TVOSAnnotationSending {
    private(set) var annotations: [TVOSAnnotationDraft] = []

    func record(_ annotation: TVOSAnnotationDraft) {
        annotations.append(annotation)
    }

    func recordedAnnotations() -> [TVOSAnnotationDraft] {
        annotations
    }
}
