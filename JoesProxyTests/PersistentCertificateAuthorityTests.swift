import Combine
import NIOSSL
import Security
import XCTest
@testable import JoesProxy

final class PersistentCertificateAuthorityTests: XCTestCase {
    private var configuration: TestAppConfiguration!
    private var store: PersistentKeychainCertificateStore!
    private var provider: PersistentCertificateAuthorityProvider!

    override func setUp() {
        super.setUp()
        configuration = TestAppConfiguration(
            proxyPort: 9090,
            logLevel: .info,
            certificateLabel: "PersistentRoot-\(UUID().uuidString)"
        )
        store = PersistentKeychainCertificateStore()
        provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
    }

    override func tearDown() {
        try? store.removeRootCertificate(label: configuration.certificateLabel)
        super.tearDown()
    }

    func testLoadOrCreatePersistsReusableRootIdentity() throws {
        let first = try provider.loadOrCreateRootCertificate()
        let second = try provider.loadOrCreateRootCertificate()

        XCTAssertEqual(first.certificateData, second.certificateData)
        XCTAssertEqual(first.privateKeyData, second.privateKeyData)
        XCTAssertEqual(store.loadRootCertificate(label: configuration.certificateLabel)?.certificateData, first.certificateData)
        XCTAssertNotNil(first.privateKeyData)
    }

    func testIssueLeafCertificateProducesSecCertificate() throws {
        _ = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "api.example.com")

        XCTAssertEqual(leaf.host, "api.example.com")
        XCTAssertFalse(leaf.privateKeyData.isEmpty)

        let certificate = SecCertificateCreateWithData(nil, leaf.certificateData as CFData)
        XCTAssertNotNil(certificate)
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate!) as String?, "api.example.com")
    }

    func testIssueLeafCertificateIncludesDNSSubjectAlternativeName() throws {
        _ = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "api.example.com")

        XCTAssertEqual(try subjectAlternativeNames(from: leaf.certificateData), [.dnsName("api.example.com")])
    }

    func testIssueLeafCertificateIncludesIPSubjectAlternativeName() throws {
        _ = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "127.0.0.1")

        XCTAssertEqual(try subjectAlternativeNames(from: leaf.certificateData), [.ipAddress(Data([127, 0, 0, 1]))])
    }

    func testIssueLeafCertificateIncludesIPv6SubjectAlternativeName() throws {
        _ = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "2001:db8::1")

        XCTAssertEqual(
            try subjectAlternativeNames(from: leaf.certificateData),
            [.ipAddress(Data([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))]
        )
    }

    func testGeneratedRootCertificateIsSelfSignedCertificateAuthority() throws {
        let root = try provider.loadOrCreateRootCertificate()
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, root.certificateData as CFData))

        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "JoesProxy Root CA")
        XCTAssertEqual(
            SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
            SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
        )

        XCTAssertEqual(try basicConstraints(from: root.certificateData), .init(isCertificateAuthority: true, pathLength: 0))
        XCTAssertEqual(try keyUsage(from: root.certificateData), [.digitalSignature, .keyCertSign, .cRLSign])
        XCTAssertEqual(try extendedKeyUsages(from: root.certificateData), [.serverAuth, .clientAuth])
        XCTAssertEqual(try subjectKeyIdentifier(from: root.certificateData), try authorityKeyIdentifier(from: root.certificateData))

        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        XCTAssertEqual(status, errSecSuccess)
        SecTrustSetAnchorCertificates(trust!, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)
        XCTAssertTrue(SecTrustEvaluateWithError(trust!, nil))
    }

    func testIssuedLeafCertificateChainsToGeneratedRootForDNSHost() throws {
        let root = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "api.example.com")

        let rootCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, root.certificateData as CFData))
        let leafCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, leaf.certificateData as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            leafCertificate,
            SecPolicyCreateSSL(true, "api.example.com" as CFString),
            &trust
        )
        XCTAssertEqual(status, errSecSuccess)
        SecTrustSetAnchorCertificates(trust!, [rootCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)
        XCTAssertTrue(SecTrustEvaluateWithError(trust!, nil))
    }

    func testIssuedLeafCertificateChainsToGeneratedRootForIPAddress() throws {
        let root = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "127.0.0.1")

        let rootCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, root.certificateData as CFData))
        let leafCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, leaf.certificateData as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            leafCertificate,
            SecPolicyCreateSSL(true, "127.0.0.1" as CFString),
            &trust
        )
        XCTAssertEqual(status, errSecSuccess)
        SecTrustSetAnchorCertificates(trust!, [rootCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)
        XCTAssertTrue(SecTrustEvaluateWithError(trust!, nil))
    }

    func testIssuedLeafCertificateMaterialIsAcceptedByNIOSSL() throws {
        _ = try provider.loadOrCreateRootCertificate()
        let leaf = try provider.issueLeafCertificate(for: "api.example.com")

        XCTAssertNoThrow(try NIOSSLCertificate(bytes: Array(leaf.certificateData), format: .der))
        XCTAssertNoThrow(try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyData), format: .pem))
    }

    func testIssueLeafCertificateRejectsEmptyHost() throws {
        _ = try provider.loadOrCreateRootCertificate()

        XCTAssertThrowsError(try provider.issueLeafCertificate(for: "")) { error in
            guard case CertificateAuthorityError.invalidHost(let host) = error else {
                return XCTFail("Expected invalidHost error, got \(error)")
            }
            XCTAssertEqual(host, "")
        }
    }

    func testLoadOrCreateReplacesStoredIdentityWithInvalidPrivateKey() throws {
        let seedProvider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let seededRoot = try seedProvider.loadOrCreateRootCertificate()
        let invalidIdentity = RootCertificateIdentity(
            label: seededRoot.label,
            subjectSummary: seededRoot.subjectSummary,
            certificateData: seededRoot.certificateData,
            privateKeyData: Data("invalid-private-key".utf8)
        )

        let memoryStore = InMemoryCertificateStore(identity: invalidIdentity)
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: memoryStore
        )

        let regenerated = try provider.loadOrCreateRootCertificate()

        XCTAssertNotEqual(regenerated.certificateData, seededRoot.certificateData)
        XCTAssertNotEqual(regenerated.privateKeyData, invalidIdentity.privateKeyData)
        XCTAssertEqual(memoryStore.removedLabels, [configuration.certificateLabel])
        XCTAssertEqual(memoryStore.savedIdentities.count, 1)
    }

    func testCurrentRootCertificateDropsInvalidPrivateKeyMaterial() throws {
        let seedProvider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let seededRoot = try seedProvider.loadOrCreateRootCertificate()
        let memoryStore = InMemoryCertificateStore(
            identity: RootCertificateIdentity(
                label: seededRoot.label,
                subjectSummary: seededRoot.subjectSummary,
                certificateData: seededRoot.certificateData,
                privateKeyData: Data("invalid-private-key".utf8)
            )
        )
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: memoryStore
        )

        let current = try XCTUnwrap(provider.currentRootCertificate())

        XCTAssertNil(current.privateKeyData)
        XCTAssertEqual(current.certificateData, seededRoot.certificateData)
    }

    func testIssueLeafCertificateThrowsWhenRootPrivateKeyMissing() throws {
        let seedProvider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let seededRoot = try seedProvider.loadOrCreateRootCertificate()
        let memoryStore = InMemoryCertificateStore(
            identity: RootCertificateIdentity(
                label: seededRoot.label,
                subjectSummary: seededRoot.subjectSummary,
                certificateData: seededRoot.certificateData,
                privateKeyData: nil
            )
        )
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: memoryStore
        )

        XCTAssertThrowsError(try provider.issueLeafCertificate(for: "api.example.com")) { error in
            guard case CertificateAuthorityError.identityUnavailable = error else {
                return XCTFail("Expected identityUnavailable error, got \(error)")
            }
        }
    }
}

private final class TestAppConfiguration: AppConfiguration {
    var proxyPort: UInt16
    var logLevel: AppLogLevel
    var verboseHTTPSLoggingEnabled = false
    var isFindDebugLoggingEnabled = false
    var appTextSizeRawValue = AppTextSize.standard.rawValue
    var isInspectorCopyRedactionEnabled = true
    var sessionSortFieldRawValue = "startedAt"
    var isSessionSortAscending = false
    var isSessionAutoScrollEnabled = false
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue
    var sessionExplorerExpandedNodeIDs: [String] = []
    var sessionInspectorSplitFraction = 0.62
    var httpsBypassDomains: [String] = []
    var httpsInterceptDomains: [String] = []
    var isNoCachingEnabled = false
    var noCachingDomains: [String] = []
    var isSystemProxyManagementEnabled = false
    var systemProxyStrictCapture = false
    var hasAcknowledgedSystemProxyRouting = false
    var showSystemProxyMenuBarItem = true
    var runInMenuBarOnly = false
    var hasCompletedInitialGuidedSetupPresentation = false
    var warnsBeforeQuittingWithUnsavedSessions = true
    var sdkEventServerEnabled = false
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue
    var manualProfileHost = ""
    var responseOverridesData: Data?
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited
    let certificateLabel: String
    var didChangePublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }

    init(proxyPort: UInt16, logLevel: AppLogLevel, certificateLabel: String) {
        self.proxyPort = proxyPort
        self.logLevel = logLevel
        self.certificateLabel = certificateLabel
    }

    func resetToDefaults() {
        proxyPort = NetworkConstants.defaultPort
        logLevel = .info
        verboseHTTPSLoggingEnabled = false
        isFindDebugLoggingEnabled = false
        appTextSizeRawValue = AppTextSize.standard.rawValue
        isInspectorCopyRedactionEnabled = true
        sessionSortFieldRawValue = "startedAt"
        isSessionSortAscending = false
        isSessionAutoScrollEnabled = false
        sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue
        sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue
        sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue
        sessionExplorerExpandedNodeIDs = []
        sessionInspectorSplitFraction = 0.62
        httpsBypassDomains = []
        httpsInterceptDomains = []
        isNoCachingEnabled = false
        noCachingDomains = []
        isSystemProxyManagementEnabled = false
        systemProxyStrictCapture = false
        hasAcknowledgedSystemProxyRouting = false
        showSystemProxyMenuBarItem = true
        runInMenuBarOnly = false
        warnsBeforeQuittingWithUnsavedSessions = true
        sdkEventServerEnabled = false
        networkThrottleConfiguration = .defaults
        responseOverridesData = nil
    }
}

private final class InMemoryCertificateStore: CertificateStore {
    private var identity: RootCertificateIdentity?
    private(set) var savedIdentities: [RootCertificateIdentity] = []
    private(set) var removedLabels: [String] = []

    init(identity: RootCertificateIdentity?) {
        self.identity = identity
    }

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        identity?.label == label ? identity : nil
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        self.identity = identity
        savedIdentities.append(identity)
    }

    func removeRootCertificate(label: String) throws {
        removedLabels.append(label)
        if identity?.label == label {
            identity = nil
        }
    }
}

private struct ParsedBasicConstraints: Equatable {
    let isCertificateAuthority: Bool
    let pathLength: Int?
}

private enum ParsedKeyUsage: Equatable, Hashable {
    case digitalSignature
    case keyEncipherment
    case keyCertSign
    case cRLSign
}

private enum ParsedExtendedKeyUsage: Equatable {
    case serverAuth
    case clientAuth
}

private enum ParsedSubjectAlternativeName: Equatable {
    case dnsName(String)
    case ipAddress(Data)
}

private enum DERParserError: Error {
    case invalidData
    case missingSubjectAlternativeName
    case missingExtension
}

private struct DERNode {
    let tag: UInt8
    let value: Data
    let children: [DERNode]
}

private func subjectAlternativeNames(from certificateData: Data) throws -> [ParsedSubjectAlternativeName] {
    let generalNames = try extensionValue(oid: [0x55, 0x1D, 0x11], in: certificateData)
    return try generalNames.children.map { name in
        switch name.tag {
        case 0x82:
            guard let dnsName = String(data: name.value, encoding: .utf8) else {
                throw DERParserError.invalidData
            }
            return .dnsName(dnsName)
        case 0x87:
            return .ipAddress(name.value)
        default:
            throw DERParserError.invalidData
        }
    }
}

private func basicConstraints(from certificateData: Data) throws -> ParsedBasicConstraints {
    let node = try extensionValue(oid: [0x55, 0x1D, 0x13], in: certificateData)
    let isCA = try node.children.first.map(parseBoolean(from:)) ?? false
    let pathLength = try node.children.dropFirst().first.map(parseInteger(from:))
    return ParsedBasicConstraints(isCertificateAuthority: isCA, pathLength: pathLength)
}

private func keyUsage(from certificateData: Data) throws -> Set<ParsedKeyUsage> {
    let node = try extensionValue(oid: [0x55, 0x1D, 0x0F], in: certificateData)
    guard node.tag == 0x03, let unusedBits = node.value.first else {
        throw DERParserError.invalidData
    }

    let bitBytes = Array(node.value.dropFirst())
    let totalBits = (bitBytes.count * 8) - Int(unusedBits)
    var usages = Set<ParsedKeyUsage>()

    for bitIndex in 0..<totalBits {
        let byte = bitBytes[bitIndex / 8]
        let mask = UInt8(1 << (7 - (bitIndex % 8)))
        guard byte & mask != 0 else {
            continue
        }

        switch bitIndex {
        case 0:
            usages.insert(.digitalSignature)
        case 2:
            usages.insert(.keyEncipherment)
        case 5:
            usages.insert(.keyCertSign)
        case 6:
            usages.insert(.cRLSign)
        default:
            continue
        }
    }

    return usages
}

private func extendedKeyUsages(from certificateData: Data) throws -> [ParsedExtendedKeyUsage] {
    let node = try extensionValue(oid: [0x55, 0x1D, 0x25], in: certificateData)
    return try node.children.map { child in
        switch child.value {
        case Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]):
            return .serverAuth
        case Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]):
            return .clientAuth
        default:
            throw DERParserError.invalidData
        }
    }
}

private func subjectKeyIdentifier(from certificateData: Data) throws -> Data {
    try extensionValue(oid: [0x55, 0x1D, 0x0E], in: certificateData).value
}

private func authorityKeyIdentifier(from certificateData: Data) throws -> Data {
    let node = try extensionValue(oid: [0x55, 0x1D, 0x23], in: certificateData)
    let keyIdentifier = try node.children.first(where: { $0.tag == 0x80 }).unwrap()
    return keyIdentifier.value
}

private func extensionValue(oid: [UInt8], in certificateData: Data) throws -> DERNode {
    let certificate = try parseDERNode(from: certificateData)
    let tbsCertificate = try firstChild(of: certificate)
    let extensionsContainer = try tbsCertificate.children.first(where: { $0.tag == 0xA3 }).unwrap()
    let extensionsSequence = try firstChild(of: extensionsContainer)

    for extensionNode in extensionsSequence.children {
        let fields = extensionNode.children
        guard let identifier = fields.first, identifier.tag == 0x06 else {
            continue
        }

        if identifier.value == Data(oid) {
            guard let octetString = fields.last, octetString.tag == 0x04 else {
                throw DERParserError.invalidData
            }
            return try parseDERNode(from: octetString.value)
        }
    }

    throw DERParserError.missingExtension
}

private func firstChild(of node: DERNode) throws -> DERNode {
    try node.children.first.unwrap()
}

private func parseBoolean(from node: DERNode) throws -> Bool {
    guard node.tag == 0x01, let value = node.value.first, node.value.count == 1 else {
        throw DERParserError.invalidData
    }
    return value != 0
}

private func parseInteger(from node: DERNode) throws -> Int {
    guard node.tag == 0x02, !node.value.isEmpty else {
        throw DERParserError.invalidData
    }

    return node.value.reduce(0) { partialResult, byte in
        (partialResult << 8) | Int(byte)
    }
}

private func parseDERNode(from data: Data) throws -> DERNode {
    var offset = data.startIndex
    let node = try parseDERNode(from: data, offset: &offset)
    guard offset == data.endIndex else {
        throw DERParserError.invalidData
    }
    return node
}

private func parseDERNode(from data: Data, offset: inout Data.Index) throws -> DERNode {
    guard offset < data.endIndex else {
        throw DERParserError.invalidData
    }

    let tag = data[offset]
    offset += 1
    let length = try parseDERLength(from: data, offset: &offset)
    guard offset + length <= data.endIndex else {
        throw DERParserError.invalidData
    }

    let value = Data(data[offset..<(offset + length)])
    offset += length

    let children: [DERNode]
    if tag & 0x20 == 0x20 || tag == 0x30 || tag == 0x31 || (tag & 0xE0) == 0xA0 {
        var childOffset = value.startIndex
        var parsedChildren: [DERNode] = []
        while childOffset < value.endIndex {
            parsedChildren.append(try parseDERNode(from: value, offset: &childOffset))
        }
        children = parsedChildren
    } else {
        children = []
    }

    return DERNode(tag: tag, value: value, children: children)
}

private func parseDERLength(from data: Data, offset: inout Data.Index) throws -> Int {
    guard offset < data.endIndex else {
        throw DERParserError.invalidData
    }

    let firstByte = data[offset]
    offset += 1

    if firstByte & 0x80 == 0 {
        return Int(firstByte)
    }

    let byteCount = Int(firstByte & 0x7F)
    guard byteCount > 0, offset + byteCount <= data.endIndex else {
        throw DERParserError.invalidData
    }

    var length = 0
    for byte in data[offset..<(offset + byteCount)] {
        length = (length << 8) | Int(byte)
    }
    offset += byteCount
    return length
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let wrapped = self else {
            throw DERParserError.invalidData
        }
        return wrapped
    }
}
