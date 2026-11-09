import Foundation

struct HTTPHeaderField: Codable, Equatable, Hashable, Sendable {
    let name: String
    let value: String
}

enum SessionScheme: String, Codable, Equatable, Sendable {
    case http
    case https
}

enum SessionInspectionKind: String, Codable, Equatable, Sendable {
    case plain
    case interceptedTLS
    case tunneledTLS
}

enum SessionBrowserMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case table
    case explorer
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table:
            return "Table"
        case .explorer:
            return "Explorer"
        case .timeline:
            return "Timeline"
        }
    }
}

enum SessionExplorerGrouping: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case byHost
    case byEndpoint
    case bySource

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byHost:
            return "By Host"
        case .byEndpoint:
            return "By Endpoint"
        case .bySource:
            return "By Source"
        }
    }
}

enum SessionExplorerHostGrouping: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case exactHosts
    case domainFamilies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exactHosts:
            return "Exact Hosts"
        case .domainFamilies:
            return "Domain Families"
        }
    }
}

enum SessionLifecycleState: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case failed
    case cancelled
}

struct SessionTiming: Codable, Equatable, Sendable {
    let startedAt: Date
    var completedAt: Date?
    var wireProfile: WireTimingProfile?

    init(startedAt: Date, completedAt: Date? = nil, wireProfile: WireTimingProfile? = nil) {
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wireProfile = wireProfile
    }

    var duration: TimeInterval? {
        guard let completedAt else {
            return nil
        }
        return completedAt.timeIntervalSince(startedAt)
    }
}

/// What JoesProxy can honestly claim about remote-device trust for a captured connection.
enum RemoteTrustState: String, Codable, Equatable, Sendable {
    case inspectedUnderCurrentCA
    case routedButTunneled
    case tlsFailure
    case bypassedOrPinned
    case noTrafficObserved
    case remoteTrustInventoryUnavailable
}

/// Captured HTTP request data associated with a proxy session.
///
/// `bodyTruncated` is `false` by default and is omitted from JSON when `false` so existing
/// serialized records remain clean. It is set to `true` when `bodyData` was truncated to
/// a recording size limit during capture or save.
///
/// `recordingBodyOmissionReason` is non-`nil` when the original capture had a body, but the body
/// was intentionally omitted from the saved recording based on the selected save fidelity mode.
///
/// `bodyDeferred` is a transient in-memory flag used during two-phase recording load.
/// When `true`, the body exists in the source file but has not yet been decoded (phase 1 of a
/// large-file open). It is never serialized to JSON. The UI shows a loading indicator instead of
/// an empty body section while this flag is set. It clears to `false` automatically when
/// `RecordingLoadCoordinator` applies the phase-2 update via `SessionStore.update(_:)`.
struct CapturedRequest: Equatable, Sendable {
    let method: String
    let scheme: SessionScheme
    let inspectionKind: SessionInspectionKind
    let inspectionReason: String?
    let host: String
    let port: Int?
    let path: String
    let headers: [HTTPHeaderField]
    let bodyData: Data?
    let bodySize: Int?
    /// `true` when `bodyData` was truncated during capture or save. Omitted from JSON when `false`.
    let bodyTruncated: Bool
    /// Present when the original captured body was intentionally omitted from a saved recording.
    let recordingBodyOmissionReason: RecordingBodyOmissionReason?
    /// Transient in-memory flag: `true` while phase-2 body decode is pending. Never serialized.
    let bodyDeferred: Bool
    /// The proxy client's peer IP (e.g. "127.0.0.1" for Mac/Simulator, a LAN IP for a device).
    /// Used to classify traffic source. Optional for backward compatibility with older recordings.
    let clientAddress: String?
    /// SHA-256 fingerprint of the local root CA used to mint the intercepted leaf, when known.
    let localCACertificateSHA256Fingerprint: String?
    /// Honest classification of what JoesProxy can claim about remote trust for this request.
    let remoteTrustState: RemoteTrustState?

    init(
        method: String,
        scheme: SessionScheme,
        inspectionKind: SessionInspectionKind = .plain,
        inspectionReason: String? = nil,
        host: String,
        port: Int?,
        path: String,
        headers: [HTTPHeaderField],
        bodyData: Data?,
        bodySize: Int?,
        bodyTruncated: Bool = false,
        recordingBodyOmissionReason: RecordingBodyOmissionReason? = nil,
        bodyDeferred: Bool = false,
        clientAddress: String? = nil,
        localCACertificateSHA256Fingerprint: String? = nil,
        remoteTrustState: RemoteTrustState? = nil
    ) {
        self.method = method
        self.scheme = scheme
        self.inspectionKind = inspectionKind
        self.inspectionReason = inspectionReason
        self.host = host
        self.port = port
        self.path = path
        self.headers = headers
        self.bodyData = bodyData
        self.bodySize = bodySize
        self.bodyTruncated = bodyTruncated
        self.recordingBodyOmissionReason = recordingBodyOmissionReason
        self.bodyDeferred = bodyDeferred
        self.clientAddress = clientAddress
        self.localCACertificateSHA256Fingerprint = localCACertificateSHA256Fingerprint
        self.remoteTrustState = remoteTrustState
    }

    /// The request's User-Agent header value, if present (case-insensitive lookup).
    var userAgent: String? {
        headers.first { $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
    }
}

extension CapturedRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case method, scheme, inspectionKind, inspectionReason, host, port, path, headers,
             bodyData, bodySize, bodyTruncated, recordingBodyOmissionReason, bodyDeferred,
             clientAddress, localCACertificateSHA256Fingerprint, remoteTrustState
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String.self, forKey: .method)
        scheme = try c.decode(SessionScheme.self, forKey: .scheme)
        inspectionKind = (try? c.decode(SessionInspectionKind.self, forKey: .inspectionKind)) ?? .plain
        inspectionReason = try c.decodeIfPresent(String.self, forKey: .inspectionReason)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        path = try c.decode(String.self, forKey: .path)
        headers = try c.decode([HTTPHeaderField].self, forKey: .headers)
        bodyData = try c.decodeIfPresent(Data.self, forKey: .bodyData)
        bodySize = try c.decodeIfPresent(Int.self, forKey: .bodySize)
        bodyTruncated = (try? c.decode(Bool.self, forKey: .bodyTruncated)) ?? false
        recordingBodyOmissionReason = try c.decodeIfPresent(
            RecordingBodyOmissionReason.self,
            forKey: .recordingBodyOmissionReason
        )
        // bodyDeferred is transient — only present in intermediate in-memory JSON during a
        // phase-1 large-file load. Falls back to false for all persisted records.
        bodyDeferred = (try? c.decode(Bool.self, forKey: .bodyDeferred)) ?? false
        clientAddress = try c.decodeIfPresent(String.self, forKey: .clientAddress)
        localCACertificateSHA256Fingerprint = try c.decodeIfPresent(
            String.self,
            forKey: .localCACertificateSHA256Fingerprint
        )
        remoteTrustState = try c.decodeIfPresent(RemoteTrustState.self, forKey: .remoteTrustState)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        try c.encode(scheme, forKey: .scheme)
        try c.encode(inspectionKind, forKey: .inspectionKind)
        try c.encodeIfPresent(inspectionReason, forKey: .inspectionReason)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(path, forKey: .path)
        try c.encode(headers, forKey: .headers)
        try c.encodeIfPresent(bodyData, forKey: .bodyData)
        try c.encodeIfPresent(bodySize, forKey: .bodySize)
        // Omit bodyTruncated from JSON when false to keep existing records clean.
        if bodyTruncated {
            try c.encode(bodyTruncated, forKey: .bodyTruncated)
        }
        try c.encodeIfPresent(recordingBodyOmissionReason, forKey: .recordingBodyOmissionReason)
        try c.encodeIfPresent(clientAddress, forKey: .clientAddress)
        try c.encodeIfPresent(
            localCACertificateSHA256Fingerprint,
            forKey: .localCACertificateSHA256Fingerprint
        )
        try c.encodeIfPresent(remoteTrustState, forKey: .remoteTrustState)
        // bodyDeferred is never persisted — it is a transient in-memory loading state only.
    }
}

/// Captured HTTP response data associated with a proxy session.
///
/// `bodyTruncated` is `false` by default and omitted from JSON when `false`. It is set to `true`
/// when `bodyData` was truncated to a recording size limit during capture or save.
///
/// `recordingBodyOmissionReason` is non-`nil` when the original capture had a body, but the body
/// was intentionally omitted from the saved recording based on the selected save fidelity mode.
///
/// `bodyDeferred` is a transient in-memory flag that mirrors the same concept on `CapturedRequest`.
/// It is set to `true` during phase-1 of a large-file recording open and cleared by phase-2.
/// It is never serialized to JSON.
struct CapturedResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let bodyData: Data?
    let bodySize: Int?
    let source: CapturedResponseSource
    let sourceDescription: String?
    /// `true` when `bodyData` was truncated during capture or save. Omitted from JSON when `false`.
    let bodyTruncated: Bool
    /// Present when the original captured body was intentionally omitted from a saved recording.
    let recordingBodyOmissionReason: RecordingBodyOmissionReason?
    /// Transient in-memory flag: `true` while phase-2 body decode is pending. Never serialized.
    let bodyDeferred: Bool
    /// Immutable MCP attribution snapshot captured at response time.
    let mcpAttribution: MCPCaptureAttribution?
    /// Local CA fingerprint used when this response was produced under TLS inspection.
    let localCACertificateSHA256Fingerprint: String?

    init(
        statusCode: Int,
        headers: [HTTPHeaderField],
        bodyData: Data?,
        bodySize: Int?,
        source: CapturedResponseSource = .upstream,
        sourceDescription: String? = nil,
        bodyTruncated: Bool = false,
        recordingBodyOmissionReason: RecordingBodyOmissionReason? = nil,
        bodyDeferred: Bool = false,
        mcpAttribution: MCPCaptureAttribution? = nil,
        localCACertificateSHA256Fingerprint: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyData = bodyData
        self.bodySize = bodySize
        self.source = source
        self.sourceDescription = sourceDescription
        self.bodyTruncated = bodyTruncated
        self.recordingBodyOmissionReason = recordingBodyOmissionReason
        self.bodyDeferred = bodyDeferred
        self.mcpAttribution = mcpAttribution
        self.localCACertificateSHA256Fingerprint = localCACertificateSHA256Fingerprint
    }
}

extension CapturedResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case statusCode, headers, bodyData, bodySize, source, sourceDescription,
             bodyTruncated, recordingBodyOmissionReason, bodyDeferred, mcpAttribution,
             localCACertificateSHA256Fingerprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        headers = try c.decode([HTTPHeaderField].self, forKey: .headers)
        bodyData = try c.decodeIfPresent(Data.self, forKey: .bodyData)
        bodySize = try c.decodeIfPresent(Int.self, forKey: .bodySize)
        source = (try? c.decode(CapturedResponseSource.self, forKey: .source)) ?? .upstream
        sourceDescription = try c.decodeIfPresent(String.self, forKey: .sourceDescription)
        bodyTruncated = (try? c.decode(Bool.self, forKey: .bodyTruncated)) ?? false
        recordingBodyOmissionReason = try c.decodeIfPresent(
            RecordingBodyOmissionReason.self,
            forKey: .recordingBodyOmissionReason
        )
        bodyDeferred = (try? c.decode(Bool.self, forKey: .bodyDeferred)) ?? false
        mcpAttribution = try c.decodeIfPresent(MCPCaptureAttribution.self, forKey: .mcpAttribution)
        localCACertificateSHA256Fingerprint = try c.decodeIfPresent(
            String.self,
            forKey: .localCACertificateSHA256Fingerprint
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(statusCode, forKey: .statusCode)
        try c.encode(headers, forKey: .headers)
        try c.encodeIfPresent(bodyData, forKey: .bodyData)
        try c.encodeIfPresent(bodySize, forKey: .bodySize)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceDescription, forKey: .sourceDescription)
        // Omit bodyTruncated from JSON when false to keep existing records clean.
        if bodyTruncated {
            try c.encode(bodyTruncated, forKey: .bodyTruncated)
        }
        try c.encodeIfPresent(recordingBodyOmissionReason, forKey: .recordingBodyOmissionReason)
        try c.encodeIfPresent(mcpAttribution, forKey: .mcpAttribution)
        try c.encodeIfPresent(
            localCACertificateSHA256Fingerprint,
            forKey: .localCACertificateSHA256Fingerprint
        )
        // bodyDeferred is never persisted — it is a transient in-memory loading state only.
    }
}

/// Captured session failure metadata shown in the inspector and failure summaries.
struct SessionFailure: Codable, Equatable, Sendable {
    /// User-facing explanation, optionally including a recovery hint.
    let message: String
    /// Optional ``NetworkFailureBucket`` raw value for filtering and diagnostics.
    let bucket: String?

    init(message: String, bucket: NetworkFailureBucket? = nil) {
        self.message = message
        self.bucket = bucket?.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(bucket, forKey: .bucket)
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case bucket
    }
}

struct SessionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var request: CapturedRequest
    var response: CapturedResponse?
    var state: SessionLifecycleState
    var timing: SessionTiming
    var failure: SessionFailure?
    /// Response bytes deliberately omitted at admission to protect bounded capture capacity.
    /// Optional for recordings written before this evidence qualification existed.
    var responseCaptureLimitedByPressure: Bool?

    init(
        id: UUID = UUID(),
        request: CapturedRequest,
        response: CapturedResponse? = nil,
        state: SessionLifecycleState = .pending,
        timing: SessionTiming,
        failure: SessionFailure? = nil
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.state = state
        self.timing = timing
        self.failure = failure
    }
}

extension SessionRecord {
    var cacheFreshness: CacheFreshnessSummary {
        CacheFreshnessEvaluator.evaluate(
            requestHeaders: request.headers,
            responseHeaders: response?.headers ?? [],
            statusCode: response?.statusCode,
            now: timing.startedAt
        )
    }
}

struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let method: String
    let host: String
    let path: String
    let scheme: SessionScheme
    let inspectionKind: SessionInspectionKind
    let inspectionReason: String?
    let mediaType: MediaType
    let statusCode: Int?
    let responseSource: CapturedResponseSource?
    let responseSourceDescription: String?
    let state: SessionLifecycleState
    let startedAt: Date
    let duration: TimeInterval?
    /// Best-effort traffic source (Mac / Simulator / Device), derived during capture.
    let source: TrafficSource
    /// Exact proxy-client IP used for device attribution and friendly-alias lookup.
    let clientAddress: String?
    /// Response body size in bytes, if the session has completed and a body was captured.
    let responseBodySize: Int?
    /// Immutable MCP effect attribution captured at response time (AJ-2/AJ-3); never re-derived
    /// from the live rule store or client registry, so it survives rule edits, disable, delete,
    /// detach, and client rename/revoke.
    let mcpAttribution: MCPCaptureAttribution?
}

extension SessionSummary {
    init(record: SessionRecord) {
        self.id = record.id
        self.method = record.request.method
        self.host = record.request.host
        self.path = record.request.path
        self.scheme = record.request.scheme
        self.inspectionKind = record.request.inspectionKind
        self.inspectionReason = record.request.inspectionReason
        self.mediaType = MediaDetector.listMediaType(for: record)
        self.statusCode = record.response?.statusCode
        self.responseSource = record.response?.source
        self.responseSourceDescription = record.response?.sourceDescription
        self.state = record.state
        self.startedAt = record.timing.startedAt
        self.duration = record.timing.duration
        self.source = TrafficSource.classify(
            clientAddress: record.request.clientAddress,
            userAgent: record.request.userAgent
        )
        self.clientAddress = record.request.clientAddress
        self.responseBodySize = record.response?.bodySize
        self.mcpAttribution = record.response?.mcpAttribution
    }
}

struct SessionExplorerNode: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case folder
        case leaf
    }

    enum Role: String, Codable, Equatable, Sendable {
        case domainFamily
        case host
        case path
        case request
    }

    let id: String
    let kind: Kind
    let role: Role
    let title: String
    let breadcrumbs: [String]
    let ancestorIDs: [String]
    let aggregateCount: Int
    let failedCount: Int
    let latestActivity: Date?
    let sessionIDs: [UUID]
    let children: [SessionExplorerNode]
    let summary: SessionSummary?

    var isFolder: Bool {
        kind == .folder
    }
}

struct SessionExplorerVisibleRow: Identifiable, Equatable, Sendable {
    let node: SessionExplorerNode
    let depth: Int

    var id: String { node.id }
}

struct SessionExplorerTree: Equatable, Sendable {
    let grouping: SessionExplorerGrouping
    let roots: [SessionExplorerNode]

    private let nodesByID: [String: SessionExplorerNode]
    private let leafNodeIDsBySessionID: [UUID: String]

    init(grouping: SessionExplorerGrouping, roots: [SessionExplorerNode]) {
        self.grouping = grouping
        self.roots = roots

        var collectedNodes: [String: SessionExplorerNode] = [:]
        var collectedLeafNodeIDs: [UUID: String] = [:]
        Self.index(
            nodes: roots,
            into: &collectedNodes,
            leafNodeIDsBySessionID: &collectedLeafNodeIDs
        )
        self.nodesByID = collectedNodes
        self.leafNodeIDsBySessionID = collectedLeafNodeIDs
    }

    static let empty = SessionExplorerTree(grouping: .byHost, roots: [])

    var isEmpty: Bool {
        roots.isEmpty
    }

    func node(id: String?) -> SessionExplorerNode? {
        guard let id else {
            return nil
        }

        return nodesByID[id]
    }

    func leafNodeID(for sessionID: UUID) -> String? {
        leafNodeIDsBySessionID[sessionID]
    }

    func visibleRows(expandedNodeIDs: Set<String>) -> [SessionExplorerVisibleRow] {
        var rows: [SessionExplorerVisibleRow] = []
        rows.reserveCapacity(nodesByID.count)
        appendVisibleRows(
            from: roots,
            depth: 0,
            expandedNodeIDs: expandedNodeIDs,
            into: &rows
        )
        return rows
    }

    func summariesByNodeID(summaryLookup: [UUID: SessionSummary]) -> [String: [SessionSummary]] {
        var summariesByNodeID: [String: [SessionSummary]] = [:]
        summariesByNodeID.reserveCapacity(nodesByID.count)

        for (nodeID, node) in nodesByID {
            guard node.isFolder else {
                continue
            }

            let summaries = node.sessionIDs
                .compactMap { summaryLookup[$0] }
                .sorted { lhs, rhs in
                    lhs.startedAt > rhs.startedAt
                }
            summariesByNodeID[nodeID] = summaries
        }

        return summariesByNodeID
    }

    private static func index(
        nodes: [SessionExplorerNode],
        into nodesByID: inout [String: SessionExplorerNode],
        leafNodeIDsBySessionID: inout [UUID: String]
    ) {
        for node in nodes {
            nodesByID[node.id] = node
            if let sessionID = node.summary?.id {
                leafNodeIDsBySessionID[sessionID] = node.id
            }
            index(
                nodes: node.children,
                into: &nodesByID,
                leafNodeIDsBySessionID: &leafNodeIDsBySessionID
            )
        }
    }

    private func appendVisibleRows(
        from nodes: [SessionExplorerNode],
        depth: Int,
        expandedNodeIDs: Set<String>,
        into rows: inout [SessionExplorerVisibleRow]
    ) {
        for node in nodes {
            rows.append(SessionExplorerVisibleRow(node: node, depth: depth))

            guard node.isFolder, expandedNodeIDs.contains(node.id), !node.children.isEmpty else {
                continue
            }

            appendVisibleRows(
                from: node.children,
                depth: depth + 1,
                expandedNodeIDs: expandedNodeIDs,
                into: &rows
            )
        }
    }
}

enum SessionExplorerBuilder {
    /// Cancellation is polled between records; cancelled builds return an empty tree.
    /// Async owners must also reject stale generations before publishing the result.
    static func build(
        from summaries: [SessionSummary],
        grouping: SessionExplorerGrouping,
        hostGrouping: SessionExplorerHostGrouping = .exactHosts,
        isCancelled: () -> Bool = { false }
    ) -> SessionExplorerTree {
        guard !summaries.isEmpty, !isCancelled() else {
            return SessionExplorerTree(grouping: grouping, roots: [])
        }

        let roots: [SessionExplorerNode]
        switch grouping {
        case .byHost:
            roots = buildHostRoots(from: summaries, hostGrouping: hostGrouping, isCancelled: isCancelled)
        case .byEndpoint:
            roots = buildEndpointRoots(from: summaries, isCancelled: isCancelled)
        case .bySource:
            roots = buildSourceRoots(from: summaries, isCancelled: isCancelled)
        }

        return SessionExplorerTree(grouping: grouping, roots: isCancelled() ? [] : roots)
    }

    private static func buildSourceRoots(from summaries: [SessionSummary], isCancelled: () -> Bool) -> [SessionExplorerNode] {
        var sourceRoots: [String: SessionExplorerFolderNodeBuilder] = [:]

        for summary in summaries {
            if isCancelled() { return [] }
            let sourceKey = summary.source.rawValue
            let title = summary.source.title
            let sourceNode = sourceRoots[sourceKey] ?? SessionExplorerFolderNodeBuilder(
                id: "source:\(sourceKey)",
                role: .domainFamily,
                title: title,
                breadcrumbs: [title],
                ancestorIDs: []
            )
            sourceRoots[sourceKey] = sourceNode
            sourceNode.absorb(summary)

            let hostKey = summary.host.lowercased()
            let hostNode = sourceNode.folderChild(
                id: "\(sourceNode.id)|host:\(hostKey)",
                role: .host,
                title: summary.host,
                breadcrumbs: sourceNode.breadcrumbs + [summary.host]
            )
            addHostPath(summary, to: hostNode)
        }

        return sourceRoots.values
            .map { $0.build() }
            .sorted(by: compareFolders)
    }

    private static func buildHostRoots(
        from summaries: [SessionSummary],
        hostGrouping: SessionExplorerHostGrouping,
        isCancelled: () -> Bool
    ) -> [SessionExplorerNode] {
        switch hostGrouping {
        case .exactHosts:
            return buildExactHostRoots(from: summaries, isCancelled: isCancelled)
        case .domainFamilies:
            return buildDomainFamilyRoots(from: summaries, isCancelled: isCancelled)
        }
    }

    private static func buildExactHostRoots(from summaries: [SessionSummary], isCancelled: () -> Bool) -> [SessionExplorerNode] {
        var hostRoots: [String: SessionExplorerFolderNodeBuilder] = [:]

        for summary in summaries {
            if isCancelled() { return [] }
            let hostKey = summary.host.lowercased()
            let hostNode = hostRoots[hostKey] ?? SessionExplorerFolderNodeBuilder(
                id: "host:\(hostKey)",
                role: .host,
                title: summary.host,
                breadcrumbs: [summary.host],
                ancestorIDs: []
            )
            hostRoots[hostKey] = hostNode
            addHostPath(summary, to: hostNode)
        }

        return hostRoots.values
            .map { $0.build() }
            .sorted(by: compareFolders)
    }

    private static func buildDomainFamilyRoots(from summaries: [SessionSummary], isCancelled: () -> Bool) -> [SessionExplorerNode] {
        var familyRoots: [String: SessionExplorerFolderNodeBuilder] = [:]

        for summary in summaries {
            if isCancelled() { return [] }
            let family = SessionExplorerHostFamily.family(for: summary.host)
            let familyKey = family.lowercased()
            let familyNode = familyRoots[familyKey] ?? SessionExplorerFolderNodeBuilder(
                id: "family:\(familyKey)",
                role: .domainFamily,
                title: family,
                breadcrumbs: [family],
                ancestorIDs: []
            )
            familyRoots[familyKey] = familyNode
            familyNode.absorb(summary)

            let hostKey = summary.host.lowercased()
            let hostNode = familyNode.folderChild(
                id: "\(familyNode.id)|host:\(hostKey)",
                role: .host,
                title: summary.host,
                breadcrumbs: familyNode.breadcrumbs + [summary.host]
            )
            addHostPath(summary, to: hostNode)
        }

        return familyRoots.values
            .map { $0.build() }
            .sorted(by: compareFolders)
    }

    private static func buildEndpointRoots(from summaries: [SessionSummary], isCancelled: () -> Bool) -> [SessionExplorerNode] {
        var pathRoots: [String: SessionExplorerFolderNodeBuilder] = [:]

        for summary in summaries {
            if isCancelled() { return [] }
            let pathSegments = SessionExplorerPath.groupingSegments(for: summary.path)
            var currentNode: SessionExplorerFolderNodeBuilder?
            var pathComponents: [String] = []

            for segment in pathSegments {
                pathComponents.append(segment)
                let segmentPath = pathComponents.joined(separator: "/")

                if let parentNode = currentNode {
                    currentNode = parentNode.folderChild(
                        id: "\(parentNode.id)|path:\(segmentPath)",
                        role: .path,
                        title: segment,
                        breadcrumbs: parentNode.breadcrumbs + [segment]
                    )
                    currentNode?.absorb(summary)
                } else {
                    let rootNode = pathRoots[segmentPath] ?? SessionExplorerFolderNodeBuilder(
                        id: "endpoint:\(segmentPath)",
                        role: .path,
                        title: segment,
                        breadcrumbs: [segment],
                        ancestorIDs: []
                    )
                    pathRoots[segmentPath] = rootNode
                    rootNode.absorb(summary)
                    currentNode = rootNode
                }
            }

            guard let terminalPathNode = currentNode else {
                continue
            }

            let hostKey = summary.host.lowercased()
            let hostNode = terminalPathNode.folderChild(
                id: "\(terminalPathNode.id)|host:\(hostKey)",
                role: .host,
                title: summary.host,
                breadcrumbs: terminalPathNode.breadcrumbs + [summary.host]
            )
            hostNode.absorb(summary)
            hostNode.addLeaf(summary)
        }

        return pathRoots.values
            .map { $0.build() }
            .sorted(by: compareFolders)
    }

    fileprivate static func compareFolders(_ lhs: SessionExplorerNode, _ rhs: SessionExplorerNode) -> Bool {
        if lhs.title == "/" && rhs.title != "/" {
            return true
        }
        if rhs.title == "/" && lhs.title != "/" {
            return false
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func addHostPath(
        _ summary: SessionSummary,
        to hostNode: SessionExplorerFolderNodeBuilder
    ) {
        hostNode.absorb(summary)

        let pathSegments = SessionExplorerPath.groupingSegments(for: summary.path)
        var currentNode = hostNode
        var pathComponents: [String] = []

        for segment in pathSegments {
            pathComponents.append(segment)
            let segmentPath = pathComponents.joined(separator: "/")
            currentNode = currentNode.folderChild(
                id: "\(hostNode.id)|path:\(segmentPath)",
                role: .path,
                title: segment,
                breadcrumbs: hostNode.breadcrumbs + pathComponents
            )
            currentNode.absorb(summary)
        }

        currentNode.addLeaf(summary)
    }
}

private enum SessionExplorerPath {
    static func groupingSegments(for path: String) -> [String] {
        let barePath = strippedPath(from: path)
        let components = barePath
            .split(separator: "/")
            .map { normalize(segment: String($0)) }

        return components.isEmpty ? ["/"] : components
    }

    private static func strippedPath(from path: String) -> String {
        let pathWithoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let normalizedPath = String(pathWithoutQuery)
        return normalizedPath.isEmpty ? "/" : normalizedPath
    }

    private static func normalize(segment: String) -> String {
        let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSegment.isEmpty else {
            return "/"
        }

        if Int(trimmedSegment) != nil || UUID(uuidString: trimmedSegment.lowercased()) != nil {
            return ":id"
        }

        return trimmedSegment
    }
}

private enum SessionExplorerHostFamily {
    private static let commonSecondLevelDomains: Set<String> = [
        "ac",
        "co",
        "com",
        "edu",
        "gov",
        "net",
        "org"
    ]

    static func family(for host: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            return host
        }

        if normalizedHost == "localhost" || normalizedHost.contains(":") || isIPv4Address(normalizedHost) {
            return normalizedHost
        }

        let labels = normalizedHost.split(separator: ".").map(String.init)
        guard labels.count > 2 else {
            return normalizedHost
        }

        let topLevelLabel = labels[labels.count - 1]
        let secondLevelLabel = labels[labels.count - 2]
        let shouldUseThreeLabels = topLevelLabel.count == 2
            && labels.count >= 3
            && commonSecondLevelDomains.contains(secondLevelLabel.lowercased())

        let labelCount = shouldUseThreeLabels ? 3 : 2
        return labels.suffix(labelCount).joined(separator: ".")
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        guard octets.count == 4 else {
            return false
        }

        return octets.allSatisfy { octet in
            guard let value = Int(octet), (0...255).contains(value) else {
                return false
            }
            return String(value) == octet || (octet == "0" && value == 0)
        }
    }
}

private final class SessionExplorerFolderNodeBuilder {
    let id: String
    let role: SessionExplorerNode.Role
    let title: String
    let breadcrumbs: [String]
    let ancestorIDs: [String]

    private var folderChildren: [String: SessionExplorerFolderNodeBuilder] = [:]
    private var leafSummaries: [SessionSummary] = []
    private var aggregateSessionIDs: [UUID] = []
    private var failedCount = 0
    private var latestActivity: Date?

    init(
        id: String,
        role: SessionExplorerNode.Role,
        title: String,
        breadcrumbs: [String],
        ancestorIDs: [String]
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.breadcrumbs = breadcrumbs
        self.ancestorIDs = ancestorIDs
    }

    func absorb(_ summary: SessionSummary) {
        aggregateSessionIDs.append(summary.id)
        if SessionExplorerFailure.isFailure(summary) {
            failedCount += 1
        }

        if let latestActivity, latestActivity > summary.startedAt {
            return
        }
        self.latestActivity = summary.startedAt
    }

    func folderChild(
        id: String,
        role: SessionExplorerNode.Role,
        title: String,
        breadcrumbs: [String]
    ) -> SessionExplorerFolderNodeBuilder {
        if let existingChild = folderChildren[id] {
            return existingChild
        }

        let child = SessionExplorerFolderNodeBuilder(
            id: id,
            role: role,
            title: title,
            breadcrumbs: breadcrumbs,
            ancestorIDs: ancestorIDs + [self.id]
        )
        folderChildren[id] = child
        return child
    }

    func addLeaf(_ summary: SessionSummary) {
        leafSummaries.append(summary)
    }

    func build() -> SessionExplorerNode {
        let builtFolderChildren = folderChildren.values
            .map { $0.build() }
            .sorted(by: SessionExplorerBuilder.compareFolders)
        let builtLeafChildren = leafSummaries
            .sorted(by: SessionExplorerFailure.compareLeafSummaries)
            .map { summary in
                SessionExplorerNode(
                    id: "session:\(summary.id.uuidString)",
                    kind: .leaf,
                    role: .request,
                    title: summary.method,
                    breadcrumbs: breadcrumbs + [summary.method],
                    ancestorIDs: ancestorIDs + [self.id],
                    aggregateCount: 1,
                    failedCount: SessionExplorerFailure.isFailure(summary) ? 1 : 0,
                    latestActivity: summary.startedAt,
                    sessionIDs: [summary.id],
                    children: [],
                    summary: summary
                )
            }

        return SessionExplorerNode(
            id: id,
            kind: .folder,
            role: role,
            title: title,
            breadcrumbs: breadcrumbs,
            ancestorIDs: ancestorIDs,
            aggregateCount: aggregateSessionIDs.count,
            failedCount: failedCount,
            latestActivity: latestActivity,
            sessionIDs: aggregateSessionIDs,
            children: builtFolderChildren + builtLeafChildren,
            summary: nil
        )
    }
}

private enum SessionExplorerFailure {
    static func isFailure(_ summary: SessionSummary) -> Bool {
        if let statusCode = summary.statusCode {
            return statusCode >= 400
        }

        return summary.state == .failed
    }

    static func compareLeafSummaries(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }

        return lhs.method.localizedCaseInsensitiveCompare(rhs.method) == .orderedAscending
    }
}
