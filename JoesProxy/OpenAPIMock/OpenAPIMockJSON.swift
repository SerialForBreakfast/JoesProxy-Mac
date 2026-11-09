import CryptoKit
import Foundation

/// JSON value used by the OpenAPI compiler. Avoids `Any` across generation and validation.
enum OpenAPIMockJSONValue: Equatable, Sendable {
    case object([String: OpenAPIMockJSONValue])
    case array([OpenAPIMockJSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null

    /// Converts a `JSONSerialization` tree into a typed value.
    static func fromAny(_ any: Any) -> OpenAPIMockJSONValue? {
        switch any {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .number(number.doubleValue)
            }
            return .integer(number.intValue)
        case let value as [Any]:
            return .array(value.compactMap(fromAny))
        case let value as [String: Any]:
            var object: [String: OpenAPIMockJSONValue] = [:]
            for (key, nested) in value {
                if let converted = fromAny(nested) {
                    object[key] = converted
                }
            }
            return .object(object)
        default:
            return nil
        }
    }

    /// Foundation tree for `JSONSerialization`.
    var asAny: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.asAny)
        case .array(let array):
            return array.map(\.asAny)
        case .string(let value):
            return value
        case .integer(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    /// Compact JSON with sorted keys so the same value always produces the same bytes.
    func encodedData() throws -> Data {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        return try JSONSerialization.data(withJSONObject: asAny, options: options)
    }

    /// SHA-256 hex digest of ``encodedData()``.
    func sha256Hex() throws -> String {
        OpenAPIMockJSONValue.sha256Hex(try encodedData())
    }

    /// SHA-256 hex digest of raw fixture bytes.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
