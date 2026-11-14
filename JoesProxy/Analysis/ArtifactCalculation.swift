import Foundation

struct ArtifactCalculation: Sendable {
    enum Kind: String, Sendable, CaseIterable, Codable {
        case rowCount, fieldStats, distinctCount, numericSummary, groupCount, topRows
    }

    struct Predicate: Sendable, Equatable {
        enum Operator: String, Sendable, CaseIterable, Codable {
            case eq, neq, gt, gte, lt, lte, isNull, isMissing, contains
        }

        let fieldPointer: String
        let parsedPointer: [String]
        let op: Operator
        let expectedScalar: Scalar?
        let expectedDecimal: Int64?

        init(_ raw: Any) throws {
            guard let dict = raw as? [String: Any],
                  let fieldPointer = dict["fieldPointer"] as? String else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            let opKey: String
            if dict["op"] != nil && dict["operator"] == nil {
                opKey = "op"
            } else if dict["operator"] != nil && dict["op"] == nil {
                opKey = "operator"
            } else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            guard let opName = dict[opKey] as? String,
                  let op = Operator(rawValue: opName) else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            let parsed = try ArtifactJSONValue.pointer(fieldPointer)
            self.fieldPointer = fieldPointer
            self.parsedPointer = parsed
            self.op = op

            switch op {
            case .isNull, .isMissing:
                guard Set(dict.keys) == ["fieldPointer", opKey] else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                self.expectedScalar = nil
                self.expectedDecimal = nil
            case .contains:
                guard Set(dict.keys) == ["fieldPointer", opKey, "value"],
                      let text = dict["value"] as? String,
                      !text.isEmpty, text.utf8.count <= 256 else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                self.expectedScalar = Scalar(type: "string", value: text)
                self.expectedDecimal = nil
            case .gt, .gte, .lt, .lte:
                guard Set(dict.keys) == ["fieldPointer", opKey, "value"],
                      let rawValue = dict["value"] else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                let lexeme: String
                if let text = rawValue as? String {
                    lexeme = text
                } else if let num = rawValue as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                    lexeme = num.stringValue
                } else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                let dec = try ArtifactDecimal(lexeme: lexeme)
                self.expectedScalar = Scalar(type: "number", value: dec.text)
                self.expectedDecimal = dec.coefficient
            case .eq, .neq:
                guard Set(dict.keys) == ["fieldPointer", opKey, "value"],
                      let rawValue = dict["value"] else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                if let text = rawValue as? String {
                    guard text.utf8.count <= 256 else { throw ArtifactAnalysisFailure.inputLimit }
                    self.expectedScalar = Scalar(type: "string", value: text)
                    self.expectedDecimal = (try? ArtifactDecimal(lexeme: text))?.coefficient
                } else if let num = rawValue as? NSNumber {
                    if CFGetTypeID(num) == CFBooleanGetTypeID() {
                        self.expectedScalar = Scalar(type: "boolean", value: num.boolValue ? "true" : "false")
                        self.expectedDecimal = nil
                    } else {
                        let dec = try ArtifactDecimal(lexeme: num.stringValue)
                        self.expectedScalar = Scalar(type: "number", value: dec.text)
                        self.expectedDecimal = dec.coefficient
                    }
                } else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
            }
        }

        func matches(_ row: ArtifactJSONValue) throws -> Bool {
            let value = row.selected(by: parsedPointer)
            switch op {
            case .isMissing:
                return value == nil
            case .isNull:
                if case .null? = value { return true }
                return false
            case .contains:
                guard case .string(let text)? = value, let needle = expectedScalar?.value else {
                    return false
                }
                return text.contains(needle)
            case .gt, .gte, .lt, .lte:
                guard let target = expectedDecimal else { return false }
                guard let value else { return false }
                if case .null = value { return false }
                guard case .number(let lexeme) = value else {
                    throw ArtifactAnalysisFailure.invalidOperand
                }
                let actual = try ArtifactDecimal(lexeme: lexeme).coefficient
                switch op {
                case .gt: return actual > target
                case .gte: return actual >= target
                case .lt: return actual < target
                case .lte: return actual <= target
                default: return false
                }
            case .eq, .neq:
                guard let expected = expectedScalar else { return false }
                let isEqual: Bool
                switch value {
                case nil, .null?:
                    isEqual = false
                case .boolean(let flag)?:
                    isEqual = expected.type == "boolean" && expected.value == (flag ? "true" : "false")
                case .number(let lexeme)?:
                    let actualDec = try ArtifactDecimal(lexeme: lexeme)
                    if expected.type == "number" {
                        isEqual = actualDec.text == expected.value
                    } else if let expCoeff = expectedDecimal {
                        isEqual = actualDec.coefficient == expCoeff
                    } else {
                        isEqual = false
                    }
                case .string(let text)?:
                    isEqual = expected.type == "string" && expected.value == text
                case .array?, .object?:
                    isEqual = false
                }
                return op == .eq ? isEqual : !isEqual
            }
        }
    }

    struct Query: Sendable {
        let kind: Kind
        let selectionPointer: String
        let fieldPointer: String
        let limit: Int
        let descending: Bool
        let predicate: Predicate?

        init(selectionPointer: String, operation: [String: Any]) throws {
            guard let name = operation["kind"] as? String, let kind = Kind(rawValue: name) else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            var allowed: Set<String> = ["kind", "where"]
            if kind != .rowCount { allowed.insert("fieldPointer") }
            if kind == .groupCount || kind == .topRows { allowed.insert("limit") }
            if kind == .topRows { allowed.insert("order") }
            guard Set(operation.keys).isSubset(of: allowed) else { throw ArtifactAnalysisFailure.malformedRequest }
            let field: String
            if kind == .rowCount { field = "" }
            else {
                guard let supplied = operation["fieldPointer"] as? String else { throw ArtifactAnalysisFailure.malformedRequest }
                field = supplied
            }
            _ = try ArtifactJSONValue.pointer(selectionPointer)
            _ = try ArtifactJSONValue.pointer(field)
            var limit = kind == .topRows ? 10 : 20
            if let supplied = operation["limit"] {
                guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue), (1...20).contains(number.intValue) else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                limit = number.intValue
            }
            let order = operation["order"] as? String ?? "desc"
            guard operation["order"] == nil || operation["order"] is String,
                  order == "asc" || order == "desc" else { throw ArtifactAnalysisFailure.malformedRequest }
            if let rawWhere = operation["where"] {
                self.predicate = try Predicate(rawWhere)
            } else {
                self.predicate = nil
            }
            self.kind = kind
            self.selectionPointer = selectionPointer
            self.fieldPointer = field
            self.limit = limit
            self.descending = order == "desc"
        }
    }

    struct Scalar: Codable, Equatable, Sendable {
        var type: String
        var value: String?
    }
    struct Group: Codable, Sendable {
        var key: Scalar
        var count: Int
    }
    struct Row: Codable, Sendable {
        var rowIndex: Int
        var value: String
    }
    struct Mean: Codable, Sendable {
        var numerator: String
        var denominator: Int
        var decimal: String
        var exact: Bool
    }
    struct Result: Codable, Sendable {
        var count: Int?
        var missing: Int?
        var null: Int?
        var fieldTypes: [String: Int]?
        var distinctCount: Int?
        var sum: String?
        var min: String?
        var max: String?
        var mean: Mean?
        var groups: [Group]?
        var totalGroups: Int?
        var omittedGroups: Int?
        var rows: [Row]?
        var eligibleRows: Int?
        var rowsNotReturned: Int?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(count, forKey: .count)
            try container.encodeIfPresent(missing, forKey: .missing)
            try container.encodeIfPresent(null, forKey: .null)
            try container.encodeIfPresent(fieldTypes, forKey: .fieldTypes)
            try container.encodeIfPresent(distinctCount, forKey: .distinctCount)
            if let sum {
                try container.encode(sum, forKey: .sum)
                try container.encode(min, forKey: .min)
                try container.encode(max, forKey: .max)
                try container.encode(mean, forKey: .mean)
            }
            try container.encodeIfPresent(groups, forKey: .groups)
            try container.encodeIfPresent(totalGroups, forKey: .totalGroups)
            try container.encodeIfPresent(omittedGroups, forKey: .omittedGroups)
            try container.encodeIfPresent(rows, forKey: .rows)
            try container.encodeIfPresent(eligibleRows, forKey: .eligibleRows)
            try container.encodeIfPresent(rowsNotReturned, forKey: .rowsNotReturned)
        }
    }
    struct Report: Codable, Sendable {
        var analyzerVersion = "artifact-calculation-v1"
        var status = "complete"
        var selectionCoverage = "complete"
        var operation: Kind
        var selectionPointer: String
        var fieldPointer: String?
        var rows: Int
        var filteredRows: Int? = nil
        var result: Result
        var analysisReused = false
    }

    struct BatchReport: Codable, Sendable {
        var analyzerVersion = "artifact-calculation-v1"
        var status = "complete"
        var selectionCoverage = "complete"
        var selectionPointer: String
        var rows: Int
        var results: [Report]
        var analysisReused = false
    }

    static func analyze(data: Data, query: Query, deadline: ContinuousClock.Instant) throws -> Report {
        var reader = try ArtifactJSONReader(data: data, deadline: deadline)
        let root = try reader.read()
        guard let collection = root.selected(by: try ArtifactJSONValue.pointer(query.selectionPointer)),
              case .array(let rows) = collection else { throw ArtifactAnalysisFailure.selectionUnavailable }
        return try analyze(rows: rows, query: query, deadline: deadline)
    }

    static func analyzeBatch(data: Data, selectionPointer: String, queries: [Query], deadline: ContinuousClock.Instant) throws -> BatchReport {
        guard (1...4).contains(queries.count) else { throw ArtifactAnalysisFailure.malformedRequest }
        var reader = try ArtifactJSONReader(data: data, deadline: deadline)
        let root = try reader.read()
        guard let collection = root.selected(by: try ArtifactJSONValue.pointer(selectionPointer)),
              case .array(let rows) = collection else { throw ArtifactAnalysisFailure.selectionUnavailable }
        return try analyzeBatch(rows: rows, selectionPointer: selectionPointer, queries: queries, deadline: deadline)
    }

    static func analyzeBatch(rows: [ArtifactJSONValue], selectionPointer: String, queries: [Query], deadline: ContinuousClock.Instant) throws -> BatchReport {
        guard (1...4).contains(queries.count) else { throw ArtifactAnalysisFailure.malformedRequest }
        var reports: [Report] = []
        reports.reserveCapacity(queries.count)
        for query in queries {
            reports.append(try analyze(rows: rows, query: query, deadline: deadline))
        }
        let overallStatus = reports.contains(where: { $0.status == "output_limited" }) ? "output_limited" : "complete"
        let batch = BatchReport(
            status: overallStatus,
            selectionPointer: selectionPointer,
            rows: rows.count,
            results: reports
        )
        guard try JSONEncoder().encode(batch).count <= 16_384 else { throw ArtifactAnalysisFailure.outputLimit }
        return batch
    }

    static func analyze(rows: [ArtifactJSONValue], query: Query, deadline: ContinuousClock.Instant) throws -> Report {
        try ArtifactSnapshotReader.check(deadline)
        guard rows.count <= 10_000 else { throw ArtifactAnalysisFailure.inputLimit }
        let pointer = try ArtifactJSONValue.pointer(query.fieldPointer)
        var result = Result()
        var report = Report(operation: query.kind, selectionPointer: query.selectionPointer,
            fieldPointer: query.kind == .rowCount ? nil : query.fieldPointer, rows: rows.count, result: result)
        if query.kind == .rowCount, query.predicate == nil {
            result.count = rows.count
            report.result = result
            return report
        }
        var matchedRowCount = 0
        var missing = 0
        var null = 0
        var types = Dictionary(uniqueKeysWithValues: ["missing", "null", "boolean", "number", "string", "array", "object"].map { ($0, 0) })
        var identities: [Data: (Scalar, Int)] = [:]
        var positive: Int64 = 0
        var negative: Int64 = 0
        var numericCount = 0
        var minimum: Int64?
        var maximum: Int64?
        var top: [(Int, Int64)] = []

        for (index, row) in rows.enumerated() {
            if index % 256 == 0 {
                guard !Task.isCancelled else { throw ArtifactAnalysisFailure.cancelled }
                guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
            }
            if let predicate = query.predicate {
                guard try predicate.matches(row) else { continue }
            }
            matchedRowCount += 1
            if query.kind == .rowCount { continue }
            let value = row.selected(by: pointer)
            let type: String
            switch value {
            case nil: type = "missing"; missing += 1
            case .null?: type = "null"; null += 1
            case .boolean?: type = "boolean"
            case .number?: type = "number"
            case .string?: type = "string"
            case .array?: type = "array"
            case .object?: type = "object"
            }
            types[type, default: 0] += 1
            if query.kind == .fieldStats { continue }
            if query.kind == .distinctCount || query.kind == .groupCount {
                if query.kind == .distinctCount && (type == "missing" || type == "null") { continue }
                let scalar = try scalar(value)
                let identity = Data((scalar.type + ":" + (scalar.value ?? "")).utf8)
                if let entry = identities[identity] { identities[identity] = (entry.0, entry.1 + 1) }
                else {
                    guard identities.count < 256 else { throw ArtifactAnalysisFailure.inputLimit }
                    identities[identity] = (scalar, 1)
                }
                continue
            }
            if type == "missing" || type == "null" { continue }
            guard case .number(let lexeme)? = value else { throw ArtifactAnalysisFailure.invalidOperand }
            let number = try ArtifactDecimal(lexeme: lexeme).coefficient
            numericCount += 1
            minimum = min(minimum ?? number, number)
            maximum = max(maximum ?? number, number)
            if query.kind == .numericSummary {
                if number >= 0 {
                    let addition = positive.addingReportingOverflow(number)
                    guard !addition.overflow else { throw ArtifactAnalysisFailure.numericOverflow }
                    positive = addition.partialValue
                } else {
                    let addition = negative.addingReportingOverflow(-number)
                    guard !addition.overflow else { throw ArtifactAnalysisFailure.numericOverflow }
                    negative = addition.partialValue
                }
            } else {
                top.append((index, number))
                top.sort {
                    if $0.1 == $1.1 { return $0.0 < $1.0 }
                    return query.descending ? $0.1 > $1.1 : $0.1 < $1.1
                }
                if top.count > query.limit { top.removeLast() }
            }
        }
        if query.predicate != nil {
            report.filteredRows = matchedRowCount
        }
        if query.kind == .rowCount {
            result.count = matchedRowCount
            report.result = result
            guard !Task.isCancelled else { throw ArtifactAnalysisFailure.cancelled }
            guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
            guard try JSONEncoder().encode(report).count <= 16_384 else { throw ArtifactAnalysisFailure.outputLimit }
            return report
        }
        result.missing = missing
        result.null = null
        switch query.kind {
        case .rowCount: break
        case .fieldStats: result.fieldTypes = types
        case .distinctCount: result.distinctCount = identities.count
        case .groupCount:
            let groups = identities.values.sorted {
                $0.1 == $1.1 ? scalarLess($0.0, $1.0) : $0.1 > $1.1
            }
            result.groups = groups.prefix(query.limit).map { Group(key: $0.0, count: $0.1) }
            result.totalGroups = groups.count
            result.omittedGroups = max(0, groups.count - query.limit)
            if groups.count > query.limit { report.status = "output_limited" }
        case .numericSummary:
            let sum = positive - negative
            result.count = numericCount
            result.sum = ArtifactDecimal(coefficient: sum).text
            result.min = minimum.map { ArtifactDecimal(coefficient: $0).text }
            result.max = maximum.map { ArtifactDecimal(coefficient: $0).text }
            if numericCount > 0 {
                let divisor = Int64(numericCount)
                var quotient = sum / divisor
                let remainder = sum % divisor
                let twice = remainder.magnitude * 2
                if twice > UInt64(divisor) || (twice == UInt64(divisor) && quotient % 2 != 0) {
                    quotient += sum < 0 ? -1 : 1
                }
                result.mean = Mean(numerator: ArtifactDecimal(coefficient: sum).text,
                    denominator: numericCount, decimal: ArtifactDecimal(coefficient: quotient).text,
                    exact: remainder == 0)
            }
        case .topRows:
            result.rows = top.map { Row(rowIndex: $0.0, value: ArtifactDecimal(coefficient: $0.1).text) }
            result.eligibleRows = numericCount
            result.rowsNotReturned = numericCount - top.count
        }
        report.result = result
        guard !Task.isCancelled else { throw ArtifactAnalysisFailure.cancelled }
        guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
        guard try JSONEncoder().encode(report).count <= 16_384 else { throw ArtifactAnalysisFailure.outputLimit }
        return report
    }

    private static func scalar(_ value: ArtifactJSONValue?) throws -> Scalar {
        switch value {
        case nil: return Scalar(type: "missing")
        case .null?: return Scalar(type: "null")
        case .boolean(let flag)?: return Scalar(type: "boolean", value: flag ? "true" : "false")
        case .number(let lexeme)?: return Scalar(type: "number", value: try ArtifactDecimal(lexeme: lexeme).text)
        case .string(let text)?:
            guard text.utf8.count <= 256 else { throw ArtifactAnalysisFailure.inputLimit }
            return Scalar(type: "string", value: text)
        default: throw ArtifactAnalysisFailure.invalidOperand
        }
    }

    private static func scalarLess(_ lhs: Scalar, _ rhs: Scalar) -> Bool {
        let order = ["missing", "null", "boolean", "number", "string"]
        if lhs.type != rhs.type { return (order.firstIndex(of: lhs.type) ?? 0) < (order.firstIndex(of: rhs.type) ?? 0) }
        if lhs.type == "number", let left = try? ArtifactDecimal(lexeme: lhs.value ?? ""),
           let right = try? ArtifactDecimal(lexeme: rhs.value ?? "") { return left < right }
        return (lhs.value ?? "").utf8.lexicographicallyPrecedes((rhs.value ?? "").utf8)
    }
}

/// One admission slot for both live calculations and saved-source preparation. A cancelled caller
/// keeps the slot until its underlying detached worker has actually exited.
@MainActor
final class ArtifactAnalysisWorker {
    private(set) var busy = false
    private let beforeWork: (@Sendable () -> Void)?

    init(beforeWork: (@Sendable () -> Void)? = nil) { self.beforeWork = beforeWork }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        guard !busy else { throw ArtifactAnalysisFailure.busy }
        busy = true
        defer { busy = false }
        let beforeWork = self.beforeWork
        let work = Task.detached(priority: .utility) {
            beforeWork?()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            guard !Task.isCancelled else { throw ArtifactAnalysisFailure.cancelled }
            return result
        } onCancel: { work.cancel() }
    }
}
