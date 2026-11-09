import Foundation

enum ArtifactAnalysisFailure: String, Error, Sendable {
    case malformedRequest = "malformed_request"
    case malformedSource = "malformed_source"
    case inputLimit = "input_limit"
    case outputLimit = "output_limit"
    case precisionLimit = "precision_limit"
    case numericOverflow = "numeric_overflow"
    case invalidOperand = "invalid_operand"
    case incompleteSelection = "incomplete_selection"
    case selectionUnavailable = "selection_unavailable"
    case sourceUnavailable = "source_unavailable"
    case sourceChanged = "source_changed"
    case cursorExpired = "cursor_expired"
    case unsupportedKind = "unsupported_kind"
    case unsupportedSchema = "unsupported_schema"
    case unsupportedCodec = "unsupported_codec"
    case busy
    case cancelled
    case deadlineExceeded = "deadline_exceeded"
}

/// Original number lexemes and byte-exact object keys are retained. Swift String equality alone
/// would incorrectly merge canonically equivalent, differently encoded JSON keys.
indirect enum ArtifactJSONValue: Sendable {
    case null, boolean(Bool), number(String), string(String)
    case array([ArtifactJSONValue])
    case object([(String, ArtifactJSONValue)])

    func member(_ key: String) -> ArtifactJSONValue? {
        guard case .object(let entries) = self else { return nil }
        let bytes = Data(key.utf8)
        return entries.first { Data($0.0.utf8) == bytes }?.1
    }

    func selected(by pointer: [String]) -> ArtifactJSONValue? {
        var value = self
        for component in pointer {
            switch value {
            case .object:
                guard let next = value.member(component) else { return nil }
                value = next
            case .array(let values):
                guard component == "0" || component.first != "0",
                      !component.isEmpty, component.utf8.allSatisfy({ (48...57).contains($0) }),
                      let index = Int(component), values.indices.contains(index) else { return nil }
                value = values[index]
            default: return nil
            }
        }
        return value
    }

    static func pointer(_ text: String) throws -> [String] {
        guard text.utf8.count <= 512 else { throw ArtifactAnalysisFailure.inputLimit }
        if text.isEmpty { return [] }
        guard text.first == "/" else { throw ArtifactAnalysisFailure.malformedRequest }
        let parts = text.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 16 else { throw ArtifactAnalysisFailure.inputLimit }
        return try parts.map { part in
            let bytes = Array(part.utf8)
            var result: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] == 126 {
                    guard index + 1 < bytes.count, bytes[index + 1] == 48 || bytes[index + 1] == 49 else {
                        throw ArtifactAnalysisFailure.malformedRequest
                    }
                    result.append(bytes[index + 1] == 48 ? 126 : 47)
                    index += 2
                } else { result.append(bytes[index]); index += 1 }
            }
            return String(decoding: result, as: UTF8.self)
        }
    }
}

struct ArtifactJSONReader {
    struct Limits: Sendable {
        var bytes = 1_048_576
        var tokens = 100_000
        var depth = 32
        var stringBytes = 262_144
        var scratchBytes = 8_388_608
        var arrayElementBytes: Int? = nil
    }

    private let bytes: Data
    private let limits: Limits
    private let deadline: ContinuousClock.Instant
    private var offset = 0
    private(set) var tokenCount = 0
    private var chargedBytes: Int

    init(data: Data, limits: Limits = Limits(), deadline: ContinuousClock.Instant) throws {
        guard data.count <= limits.scratchBytes else { throw ArtifactAnalysisFailure.inputLimit }
        guard data.count <= limits.bytes, String(data: data, encoding: .utf8) != nil else {
            throw data.count > limits.bytes ? ArtifactAnalysisFailure.inputLimit : .malformedSource
        }
        self.bytes = data
        self.limits = limits
        self.deadline = deadline
        self.chargedBytes = data.count
    }

    mutating func read() throws -> ArtifactJSONValue {
        try check()
        let result = try value(depth: 0)
        try whitespace()
        guard offset == bytes.count else { throw ArtifactAnalysisFailure.malformedSource }
        try check()
        return result
    }

    private func check() throws {
        guard !Task.isCancelled else { throw ArtifactAnalysisFailure.cancelled }
        guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
    }

    private mutating func charge(_ count: Int) throws {
        guard count <= limits.scratchBytes - chargedBytes else { throw ArtifactAnalysisFailure.inputLimit }
        chargedBytes += count
    }

    private mutating func whitespace() throws {
        while offset < bytes.count, [9, 10, 13, 32].contains(byte(at: offset)) {
            offset += 1
            if offset % 65_536 == 0 { try check() }
        }
    }

    private func byte(at index: Int) -> UInt8 { bytes[bytes.startIndex + index] }

    private func slice(_ range: Range<Int>) -> Data {
        Data(bytes[(bytes.startIndex + range.lowerBound)..<(bytes.startIndex + range.upperBound)])
    }

    private mutating func value(depth: Int) throws -> ArtifactJSONValue {
        try whitespace()
        tokenCount += 1
        guard depth <= limits.depth, tokenCount <= limits.tokens, offset < bytes.count else {
            throw offset == bytes.count ? ArtifactAnalysisFailure.malformedSource : .inputLimit
        }
        if tokenCount % 256 == 0 { try check() }
        try charge(128)
        switch byte(at: offset) {
        case 110: try literal("null"); return .null
        case 116: try literal("true"); return .boolean(true)
        case 102: try literal("false"); return .boolean(false)
        case 34: return .string(try string())
        case 91:
            guard depth < limits.depth else { throw ArtifactAnalysisFailure.inputLimit }
            offset += 1
            try whitespace()
            var entries: [ArtifactJSONValue] = []
            if consume(93) { return .array(entries) }
            repeat {
                let start = offset
                entries.append(try value(depth: depth + 1))
                if let maximum = limits.arrayElementBytes, offset - start > maximum { throw ArtifactAnalysisFailure.inputLimit }
                try whitespace()
                if consume(93) { return .array(entries) }
                guard consume(44) else { throw ArtifactAnalysisFailure.malformedSource }
            } while true
        case 123:
            guard depth < limits.depth else { throw ArtifactAnalysisFailure.inputLimit }
            offset += 1
            try whitespace()
            var entries: [(String, ArtifactJSONValue)] = []
            var keys = Set<Data>()
            if consume(125) { return .object(entries) }
            repeat {
                try whitespace()
                let key = try string()
                guard keys.insert(Data(key.utf8)).inserted else { throw ArtifactAnalysisFailure.malformedSource }
                try charge(key.utf8.count + 64)
                try whitespace()
                guard consume(58) else { throw ArtifactAnalysisFailure.malformedSource }
                entries.append((key, try value(depth: depth + 1)))
                try whitespace()
                if consume(125) { return .object(entries) }
                guard consume(44) else { throw ArtifactAnalysisFailure.malformedSource }
            } while true
        case 45, 48...57: return .number(try number())
        default: throw ArtifactAnalysisFailure.malformedSource
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, self.byte(at: offset) == byte else { return false }
        offset += 1
        return true
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard consume(byte) else { throw ArtifactAnalysisFailure.malformedSource }
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ArtifactAnalysisFailure.malformedSource }
        var escaped = false
        while offset < bytes.count {
            guard offset - start <= limits.stringBytes else { throw ArtifactAnalysisFailure.inputLimit }
            if offset % 65_536 == 0 { try check() }
            let byte = self.byte(at: offset)
            offset += 1
            if !escaped && byte == 34 {
                let token = slice(start..<offset)
                guard let result = try? JSONDecoder().decode(String.self, from: token),
                      result.utf8.count <= limits.stringBytes else { throw ArtifactAnalysisFailure.malformedSource }
                try charge(token.count + result.utf8.count)
                return result
            }
            if byte < 32 { throw ArtifactAnalysisFailure.malformedSource }
            if escaped { escaped = false } else { escaped = byte == 92 }
        }
        throw ArtifactAnalysisFailure.malformedSource
    }

    private mutating func number() throws -> String {
        let start = offset
        _ = consume(45)
        if !consume(48) { try digits() }
        if consume(46) { try digits() }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            try digits()
        }
        guard offset - start <= 128 else { throw ArtifactAnalysisFailure.inputLimit }
        try charge(offset - start)
        return String(decoding: slice(start..<offset), as: UTF8.self)
    }

    private mutating func digits() throws {
        let start = offset
        while offset < bytes.count, (48...57).contains(byte(at: offset)) {
            offset += 1
            guard offset - start <= 128 else { throw ArtifactAnalysisFailure.inputLimit }
        }
        guard offset > start else { throw ArtifactAnalysisFailure.malformedSource }
    }
}

/// Six fractional places represented as checked integer coefficients, never binary floats.
struct ArtifactDecimal: Sendable, Comparable {
    let coefficient: Int64
    static let scale: Int64 = 1_000_000

    init(coefficient: Int64) { self.coefficient = coefficient }

    init(lexeme: String) throws {
        guard lexeme.utf8.count <= 128 else { throw ArtifactAnalysisFailure.inputLimit }
        var text = lexeme.lowercased()
        let negative = text.first == "-"
        if negative { text.removeFirst() }
        let pieces = text.split(separator: "e", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { throw ArtifactAnalysisFailure.malformedSource }
        let exponent: Int
        if pieces.count == 2 {
            guard let parsed = Int(pieces[1]), (-256...256).contains(parsed) else {
                throw ArtifactAnalysisFailure.precisionLimit
            }
            exponent = parsed
        } else { exponent = 0 }
        let decimal = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = decimal.joined()
        var places = (decimal.count == 2 ? decimal[1].count : 0) - exponent
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { coefficient = 0; return }
        while digits.last == "0", places > 0 { digits.removeLast(); places -= 1 }
        guard places <= 6 else { throw ArtifactAnalysisFailure.precisionLimit }
        guard digits.count - places <= 12 else { throw ArtifactAnalysisFailure.numericOverflow }
        let padding = 6 - places
        guard padding >= 0, digits.count + padding <= 18,
              let value = Int64(digits + String(repeating: "0", count: padding)) else {
            throw ArtifactAnalysisFailure.numericOverflow
        }
        coefficient = negative ? -value : value
    }

    var text: String {
        let magnitude = coefficient.magnitude
        let whole = magnitude / UInt64(Self.scale)
        let remainder = magnitude % UInt64(Self.scale)
        var fraction = String(remainder)
        fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
        while fraction.last == "0" { fraction.removeLast() }
        return (coefficient < 0 ? "-" : "") + String(whole) + (fraction.isEmpty ? "" : "." + fraction)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.coefficient < rhs.coefficient }
}
