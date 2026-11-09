//
//  SyntheticCollectionInjectionEngine.swift
//  JoesProxy
//
//  In-flight interceptor and collection injection coordinator for live wire responses.
//

import Foundation
import os

/// Hard ceiling on the response body synthetic injection will parse/re-serialize (P2/Guard,
/// memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6: "warn or refuse before
/// 100%-CPU schema-inference on a large streamed body" — a real, reproduced pathology, not a
/// hypothetical). Deliberately larger than `MCPMutationValidator.maxInlineBodyBytes`/
/// `OpenAPIMockPackBudget.maxCompiledBodyBytes` (65,536 bytes): those bound an *agent-authored*
/// body; this bounds a real upstream *catalog response*, which legitimately runs several hundred
/// KB. The refusal is a safety ceiling on pathological size, not a budget on ordinary content.
enum SyntheticInjectionBudget {
    static let maxResponseBodyBytes = 5 * 1_048_576
}

/// Deliberately a plain lock-protected class, not `@MainActor` (its original declaration, changed
/// while wiring this into live traffic — see Tasks.md Workstream AH P3): `processResponse` must be
/// callable from the synchronous NIO completion callback in `ConnectionHandler.
/// executeUpstreamRequest`, exactly the same constraint `LiveTransformationActivationTracker`
/// documents for the sibling live-rewrite feature. Actor-hopping there would mean restructuring an
/// already-shipped hot path into a fully async flow for one plan-matching lookup. Registration
/// (`registerPlan`/`removePlan`) still happens from the MCP dispatch/main-actor side — the lock is
/// what makes that safe to interleave with hot-path reads, not actor isolation.
final class SyntheticCollectionInjectionEngine: @unchecked Sendable {
    static let shared = SyntheticCollectionInjectionEngine()
    private let logger = Logger(subsystem: "com.joesproxyapp", category: "SyntheticInjection")

    private let lock = NSLock()
    private var activePlans: [UUID: SyntheticCollectionInjectionPlan] = [:]
    private var diagnosticsByPlan: [UUID: SyntheticInjectionDiagnostics] = [:]
    private var registrations: [UUID: UUID] = [:]

    func registerPlan(_ plan: SyntheticCollectionInjectionPlan) {
        lock.lock()
        defer { lock.unlock() }
        activePlans[plan.id] = plan
        registrations[plan.id] = UUID()
        diagnosticsByPlan[plan.id] = SyntheticInjectionDiagnostics()
    }

    func removePlan(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activePlans.removeValue(forKey: id)
        registrations.removeValue(forKey: id)
        diagnosticsByPlan.removeValue(forKey: id)
    }

    func clearAllPlans() {
        lock.lock()
        defer { lock.unlock() }
        activePlans.removeAll()
        registrations.removeAll()
        diagnosticsByPlan.removeAll()
    }

    func allPlans() -> [SyntheticCollectionInjectionPlan] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activePlans.values)
    }

    func diagnostics(planID: UUID) -> SyntheticInjectionDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsByPlan[planID]
    }

    private func record(_ reason: SyntheticInjectionReason, plan: SyntheticCollectionInjectionPlan,
                        attribution: SyntheticInjectionAttribution? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard activePlans[plan.id] == plan else { return }
        if let attribution, registrations[plan.id] != attribution.registrationID { return }
        diagnosticsByPlan[plan.id]?.record(reason)
        if let attribution { diagnosticsByPlan[plan.id]?.recordReceipt(reason, attribution: attribution) }
    }

    /// Called from write completion and asynchronous capture-ID resolution, in either order.
    /// Evicted/stopped receipts are never recreated, and terminal write outcomes are immutable.
    func updateReceipt(requestID: UUID, sessionID: UUID? = nil, writeSucceeded: Bool? = nil) {
        lock.lock()
        defer { lock.unlock() }
        for planID in Array(diagnosticsByPlan.keys) {
            guard var diagnostic = diagnosticsByPlan[planID],
                  let index = diagnostic.receipts.firstIndex(where: { $0.requestID == requestID }),
                  diagnostic.receipts[index].registrationID == registrations[planID] else { continue }
            if let sessionID { diagnostic.receipts[index].sessionID = sessionID }
            if let writeSucceeded, diagnostic.receipts[index].deliveryState == .pending {
                diagnostic.receipts[index].deliveryState = writeSucceeded ? .downstreamWriteSucceeded : .downstreamWriteFailed
                diagnostic.receipts[index].deliveryObservedAt = Date()
            }
            diagnosticsByPlan[planID] = diagnostic
        }
    }

    func hasReceipt(requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsByPlan.values.contains { $0.receipts.contains { $0.requestID == requestID } }
    }

    /// Call once at the streaming response head, including traffic that will not be buffered.
    /// This reports eligibility, not successful transformation. Pure queries remain side-effect free.
    func observeEligibility(requestURL: String, headers: [HTTPHeaderField],
                            bypassReason: SyntheticInjectionReason? = nil, requestID: UUID = UUID()) -> Bool {
        var matched = false
        for (plan, registrationID) in registeredPlans() where plan.isEnabled {
            func record(_ reason: SyntheticInjectionReason, plan: SyntheticCollectionInjectionPlan) {
                self.record(reason, plan: plan, attribution: .init(requestID: requestID, registrationID: registrationID))
            }
            if !urlMatchesPattern(url: requestURL, pattern: plan.urlPattern) { record(.urlMismatch, plan: plan) }
            else if !plan.clientScope.matches(headers: headers) { record(.clientScopeMismatch, plan: plan) }
            else {
                matched = true
                if let bypassReason { record(bypassReason, plan: plan) }
            }
        }
        return matched
    }

    func recordBufferLimit(requestURL: String, headers: [HTTPHeaderField], requestID: UUID = UUID()) {
        for (plan, registrationID) in registeredPlans() where plan.isEnabled && urlMatchesPattern(url: requestURL, pattern: plan.urlPattern)
            && plan.clientScope.matches(headers: headers) {
            record(.inputTooLarge, plan: plan, attribution: .init(requestID: requestID, registrationID: registrationID))
        }
    }

    private func registeredPlans() -> [(SyntheticCollectionInjectionPlan, UUID)] {
        lock.lock()
        defer { lock.unlock() }
        return activePlans.values.compactMap { plan in registrations[plan.id].map { (plan, $0) } }
    }

    func hasActivePlans(for requestURL: String? = nil, headers: [HTTPHeaderField] = []) -> Bool {
        lock.lock()
        let plans = Array(activePlans.values)
        lock.unlock()
        if let requestURL {
            return plans.contains { plan in
                plan.isEnabled &&
                urlMatchesPattern(url: requestURL, pattern: plan.urlPattern) &&
                plan.clientScope.matches(headers: headers)
            }
        }
        return plans.contains { $0.isEnabled }
    }

    /// Evaluates and applies collection injection to an incoming response body. Snapshots the plan
    /// list under lock, then evaluates/transforms outside it — `executeInjection` never touches
    /// `activePlans`, so there's no need to hold the lock for the (potentially non-trivial) JSON
    /// parse/re-serialize work.
    func processResponse(
        responseData: Data,
        requestURL: String,
        requestHeaders: [HTTPHeaderField],
        requestID: UUID = UUID()
    ) -> (transformedData: Data, result: SyntheticInjectionResult)? {
        let plans = registeredPlans()
        for (plan, registrationID) in plans where plan.isEnabled {
            if urlMatchesPattern(url: requestURL, pattern: plan.urlPattern) {
                if !plan.clientScope.matches(headers: requestHeaders) {
                    continue
                }

                guard let transformed = executeInjection(
                    plan: plan,
                    responseData: responseData,
                    requestURL: requestURL,
                    requestHeaders: requestHeaders,
                    attribution: .init(requestID: requestID, registrationID: registrationID)
                ) else {
                    continue
                }

                return transformed
            }
        }
        return nil
    }

    // MARK: - Core Execution

    func executeInjection(
        plan: SyntheticCollectionInjectionPlan,
        responseData: Data,
        requestURL: String,
        requestHeaders: [HTTPHeaderField] = [],
        attribution: SyntheticInjectionAttribution? = nil
    ) -> (transformedData: Data, result: SyntheticInjectionResult)? {
        func record(_ reason: SyntheticInjectionReason, plan: SyntheticCollectionInjectionPlan) {
            self.record(reason, plan: plan, attribution: attribution)
        }
        // Guard, not a feature (P2/memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md
        // §6): refuse before full-tree JSON parse + `.sortedKeys` re-serialize on a pathologically
        // large response — a real field session drove this to 100% CPU on a large streamed catalog
        // body. Fail-open (skip injection, serve the real untransformed response) exactly like every
        // other early-exit in this function, not a hang or an unbounded allocation.
        guard responseData.count <= SyntheticInjectionBudget.maxResponseBodyBytes else {
            logger.warning(
                "Refusing synthetic injection: response body \(responseData.count, privacy: .public) bytes exceeds \(SyntheticInjectionBudget.maxResponseBodyBytes, privacy: .public)-byte ceiling for \(requestURL, privacy: .private)."
            )
            record(.inputTooLarge, plan: plan)
            return nil
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: responseData, options: [.mutableContainers, .fragmentsAllowed]) else {
            record(.invalidJSON, plan: plan)
            return nil
        }

        // 1. Resolve Target Array and Extract Template Item
        let templateItem: [String: Any]
        do { templateItem = try extractTemplateItem(from: jsonObject, keypath: plan.collectionKeypath) }
        catch let reason as SyntheticInjectionReason {
            record(reason, plan: plan)
            return nil
        } catch {
            record(.transformationFailed, plan: plan)
            return nil
        }

        // 2. Resolve Bound Asset URL
        let assetURL: String?
        if let custom = plan.customAssetURL, !custom.isEmpty {
            assetURL = custom
        } else if let kind = plan.boundAssetKind {
            let assets = SyntheticAssetCatalog.availableAssets()
            assetURL = assets.first(where: { $0.kind == kind })?.localURL
        } else {
            assetURL = nil
        }

        // 3. Synthesize Conforming Item
        let synthesizedItem = SchemaInferredSynthesizer.synthesizeItem(
            from: templateItem,
            overrides: plan.fieldOverrides,
            boundAssetURL: assetURL
        )

        // 4. Inject Item into Collection
        guard let (modifiedObject, beforeCount, afterCount) = SchemaInferredSynthesizer.injectItem(
            into: jsonObject,
            at: plan.collectionKeypath,
            synthesizedItem: synthesizedItem,
            position: plan.position
        ) else {
            record(.transformationFailed, plan: plan)
            return nil
        }

        guard let outputData = try? JSONSerialization.data(withJSONObject: modifiedObject, options: [.prettyPrinted, .sortedKeys]) else {
            record(.encodingFailed, plan: plan)
            return nil
        }
        guard outputData.count <= SyntheticInjectionBudget.maxResponseBodyBytes else {
            record(.outputTooLarge, plan: plan)
            return nil
        }

        let userAgent = requestHeaders.first(where: { $0.name.lowercased() == "user-agent" })?.value

        let result = SyntheticInjectionResult(
            planID: plan.id,
            matchedURL: requestURL,
            wasTransformed: true,
            injectedItemKeys: Array(synthesizedItem.keys),
            collectionCountBefore: beforeCount,
            collectionCountAfter: afterCount,
            clientUserAgent: userAgent
        )

        record(.transformed, plan: plan)
        return (outputData, result)
    }

    // MARK: - Template Extraction

    private func extractTemplateItem(from jsonObject: Any, keypath: String) throws -> [String: Any] {
        let clean = keypath.trimmingCharacters(in: .whitespacesAndNewlines)

        if clean == "$" || clean.isEmpty {
            return try template(in: jsonObject)
        }

        guard let dict = jsonObject as? [String: Any] else { throw SyntheticInjectionReason.collectionMissing }
        let components = clean.replacingOccurrences(of: "$", with: "")
            .components(separatedBy: ".")
            .filter { !$0.isEmpty }

        var current: Any = dict
        for comp in components {
            if let curDict = current as? [String: Any], let next = curDict[comp] {
                current = next
            } else {
                throw SyntheticInjectionReason.collectionMissing
            }
        }

        return try template(in: current)
    }

    private func template(in value: Any) throws -> [String: Any] {
        guard let array = value as? [Any] else { throw SyntheticInjectionReason.collectionNotArray }
        guard !array.isEmpty else { throw SyntheticInjectionReason.emptyCollection }
        guard let objects = value as? [[String: Any]], let first = objects.first else {
            throw SyntheticInjectionReason.templateNotObject
        }
        return first
    }

    private func urlMatchesPattern(url: String, pattern: String) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        if url.contains(pattern) { return true }

        let cleanPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPattern.hasPrefix("*") && cleanPattern.hasSuffix("*") {
            let sub = cleanPattern.dropFirst().dropLast()
            return url.contains(sub)
        } else if cleanPattern.hasPrefix("*") {
            let sub = cleanPattern.dropFirst()
            return url.hasSuffix(String(sub))
        } else if cleanPattern.hasSuffix("*") {
            let sub = cleanPattern.dropLast()
            return url.hasPrefix(String(sub))
        }

        return url == cleanPattern
    }
}
