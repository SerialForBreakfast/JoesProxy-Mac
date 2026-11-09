import Foundation

/// A structural description of JSON — property names, scalar types, and array cardinality —
/// deliberately never values. `.mixed` records that more than one incompatible shape was observed
/// at the same tree position across samples (e.g. sometimes a string, sometimes an object),
/// reported honestly rather than picked arbitrarily.
indirect enum JSONShape: Hashable, Sendable {
    case string
    case number
    case bool
    case null
    case object([String: JSONShape])
    case array(elementShape: JSONShape?, minCount: Int, maxCount: Int)
    case mixed([JSONShape])
}

/// Deterministic, policy-agnostic profiler for captured JSON response bodies. Stays free of any
/// MCP disclosure-policy dependency (matching the existing layering — no `Sessions/*.swift` file
/// imports from `MCP/`); property-name gating against the active `MCPDisclosureProfileID` happens
/// at the MCP serialization boundary, not here. This is a deterministic parser and shape
/// aggregator, not an LLM.
enum JSONStructuralProfiler {
    enum Status: Equatable, Sendable {
        /// At least one sample parsed as JSON and contributed to `shape`.
        case complete
        /// Every sample failed to parse as JSON.
        case malformed
        /// No samples were provided at all.
        case empty
    }

    struct Profile: Equatable, Sendable {
        var status: Status
        /// `nil` only when `status != .complete`.
        var shape: JSONShape?
        /// Number of samples that successfully parsed and contributed to `shape` — may be less
        /// than the number of samples passed in if some were malformed or empty.
        var sampleCount: Int
        var schemaFingerprint: JSONSchemaShapeFingerprint?
    }

    /// Profiles a single captured response body.
    static func profile(bodyData: Data) -> Profile {
        profile(bodies: [bodyData])
    }

    /// Profiles a bounded set of captured response bodies, merging their shapes into one
    /// representative structure — repeated sibling shapes (e.g. an array of `{title, id}`
    /// objects) merge into one shape, not N separate ones.
    static func profile(bodies: [Data]) -> Profile {
        guard !bodies.isEmpty else {
            return Profile(status: .empty, shape: nil, sampleCount: 0, schemaFingerprint: nil)
        }

        var mergedShape: JSONShape?
        var sampleCount = 0

        for body in bodies {
            guard !body.isEmpty, let jsonObject = try? JSONTreeParser.parseJSONObject(from: body) else {
                continue
            }
            let shape = shapeOf(jsonObject)
            mergedShape = mergedShape.map { merge($0, shape) } ?? shape
            sampleCount += 1
        }

        guard let shape = mergedShape, sampleCount > 0 else {
            return Profile(status: .malformed, shape: nil, sampleCount: 0, schemaFingerprint: nil)
        }

        return Profile(
            status: .complete,
            shape: shape,
            sampleCount: sampleCount,
            schemaFingerprint: JSONSchemaShapeFingerprint.compute(for: shape)
        )
    }

    private static func shapeOf(_ value: Any) -> JSONShape {
        switch value {
        case let dict as [String: Any]:
            var properties: [String: JSONShape] = [:]
            for (key, propertyValue) in dict {
                properties[key] = shapeOf(propertyValue)
            }
            return .object(properties)
        case let array as [Any]:
            guard let first = array.first else {
                return .array(elementShape: nil, minCount: 0, maxCount: 0)
            }
            var elementShape = shapeOf(first)
            for element in array.dropFirst() {
                elementShape = merge(elementShape, shapeOf(element))
            }
            return .array(elementShape: elementShape, minCount: array.count, maxCount: array.count)
        case is String:
            return .string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool
            }
            return .number
        case is NSNull:
            return .null
        default:
            return .string
        }
    }

    private static func merge(_ lhs: JSONShape, _ rhs: JSONShape) -> JSONShape {
        switch (lhs, rhs) {
        case (.string, .string):
            return .string
        case (.number, .number):
            return .number
        case (.bool, .bool):
            return .bool
        case (.null, .null):
            return .null
        case (.object(let propsLHS), .object(let propsRHS)):
            var merged = propsLHS
            for (key, rightShape) in propsRHS {
                merged[key] = merged[key].map { merge($0, rightShape) } ?? rightShape
            }
            return .object(merged)
        case (.array(let elementLHS, let minLHS, let maxLHS), .array(let elementRHS, let minRHS, let maxRHS)):
            let mergedElement: JSONShape?
            switch (elementLHS, elementRHS) {
            case (nil, nil):
                mergedElement = nil
            case (let element?, nil), (nil, let element?):
                mergedElement = element
            case (let left?, let right?):
                mergedElement = merge(left, right)
            }
            return .array(
                elementShape: mergedElement,
                minCount: min(minLHS, minRHS),
                maxCount: max(maxLHS, maxRHS)
            )
        default:
            let lhsAlternatives: [JSONShape]
            if case .mixed(let existing) = lhs {
                lhsAlternatives = existing
            } else {
                lhsAlternatives = [lhs]
            }
            let rhsAlternatives: [JSONShape]
            if case .mixed(let existing) = rhs {
                rhsAlternatives = existing
            } else {
                rhsAlternatives = [rhs]
            }
            return .mixed(lhsAlternatives + rhsAlternatives)
        }
    }
}
