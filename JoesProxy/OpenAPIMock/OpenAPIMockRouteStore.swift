import Foundation

/// Hot-path decision for a matched mock-pack route. Missing fixtures become fail-open at the caller.
struct OpenAPIMockRouteDecision: Sendable {
    var packID: OpenAPIMockPackID
    var routeID: String
    var variant: OpenAPIMockResponseVariant
    var status: Int
    var headers: [String: String]
    var body: Data
    var mcpProvenance: MCPProvenance?
}

/// In-memory route table consulted by the proxy before ordinary response overrides.
///
/// Concurrency: actor-isolated so ConnectionHandler can await decisions off the main actor
/// without racing coordinator install/remove.
actor OpenAPIMockRouteStore {
    private struct InstalledPack: Sendable {
        var packID: OpenAPIMockPackID
        var origin: OpenAPIMockOrigin
        var routes: [OpenAPIMockRoute]
        var fixturesByVariantID: [String: OpenAPIMockCompiledFixture]
        var mcpProvenance: MCPProvenance?
    }

    private var packs: [UUID: InstalledPack] = [:]
    private var metricsByPackID: [UUID: OpenAPIMockPackMetrics] = [:]

    /// Atomically replaces any previous install for `packID`. Throws if a route lacks its default fixture.
    func install(
        packID: OpenAPIMockPackID,
        origin: OpenAPIMockOrigin,
        routes: [OpenAPIMockRoute],
        fixtures: [String: OpenAPIMockCompiledFixture],
        mcpProvenance: MCPProvenance?
    ) throws {
        for route in routes {
            guard let defaultID = route.variantIDs.first, fixtures[defaultID] != nil else {
                throw OpenAPIMockPackError.missingFixture
            }
        }
        packs[packID.rawValue] = InstalledPack(
            packID: packID,
            origin: origin,
            routes: routes,
            fixturesByVariantID: fixtures,
            mcpProvenance: mcpProvenance
        )
        if metricsByPackID[packID.rawValue] == nil {
            metricsByPackID[packID.rawValue] = OpenAPIMockPackMetrics()
        }
    }

    func remove(packID: OpenAPIMockPackID) {
        packs.removeValue(forKey: packID.rawValue)
    }

    func metrics(packID: OpenAPIMockPackID) -> OpenAPIMockPackMetrics {
        metricsByPackID[packID.rawValue] ?? OpenAPIMockPackMetrics()
    }

    func servingPackIDs() -> [OpenAPIMockPackID] {
        packs.values.map(\.packID)
    }

    /// Returns a local fixture when a serving pack matches. Origin-only misses increment ``misses`` and fail open.
    func decision(for request: CapturedRequest, now: Date = Date()) -> OpenAPIMockRouteDecision? {
        let matchRequest = OpenAPIMockMatchRequest.from(request)
        var originMatched = false
        for pack in packs.values where pack.origin == matchRequest.origin {
            originMatched = true
            let selected: OpenAPIMockRoute?
            do {
                selected = try OpenAPIMockRouteMatcher.select(routes: pack.routes, request: matchRequest)
            } catch {
                recordMiss(packID: pack.packID, now: now)
                return nil
            }
            guard let route = selected else { continue }
            let variantID = requestedVariantID(
                route: route,
                fixtures: pack.fixturesByVariantID,
                requested: matchRequest.requestedVariant
            ) ?? route.variantIDs.first
            guard let variantID, let fixture = pack.fixturesByVariantID[variantID] else {
                recordMiss(packID: pack.packID, now: now)
                return nil
            }
            recordHit(packID: pack.packID, routeID: route.id, now: now)
            return OpenAPIMockRouteDecision(
                packID: pack.packID,
                routeID: route.id,
                variant: fixture.variant,
                status: fixture.status,
                headers: fixture.headers,
                body: fixture.body,
                mcpProvenance: pack.mcpProvenance
            )
        }
        if originMatched, let pack = packs.values.first(where: { $0.origin == matchRequest.origin }) {
            recordMiss(packID: pack.packID, now: now)
        }
        return nil
    }

    private func requestedVariantID(
        route: OpenAPIMockRoute,
        fixtures: [String: OpenAPIMockCompiledFixture],
        requested: String?
    ) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        return route.variantIDs.first { id in
            fixtures[id]?.variant.name == requested
        }
    }

    private func recordHit(packID: OpenAPIMockPackID, routeID: String, now: Date) {
        var metrics = metricsByPackID[packID.rawValue] ?? OpenAPIMockPackMetrics()
        metrics.hits += 1
        metrics.lastMatchedAt = now
        metrics.operationHits[routeID, default: 0] += 1
        metricsByPackID[packID.rawValue] = metrics
    }

    private func recordMiss(packID: OpenAPIMockPackID, now: Date) {
        var metrics = metricsByPackID[packID.rawValue] ?? OpenAPIMockPackMetrics()
        metrics.misses += 1
        metrics.lastMatchedAt = now
        metricsByPackID[packID.rawValue] = metrics
    }
}
