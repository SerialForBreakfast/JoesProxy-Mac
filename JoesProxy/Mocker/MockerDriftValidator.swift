import Foundation

/// Classification of structural contract drift between a Mocker fixture and live wire traffic.
enum MockerDriftKind: String, Sendable, Codable, Equatable {
    case missingInFixture = "missing_in_fixture"
    case extraInFixture = "extra_in_fixture"
    case typeMismatch = "type_mismatch"
    case nullabilityMismatch = "nullability_mismatch"
    case statusCodeMismatch = "status_code_mismatch"

    var description: String {
        switch self {
        case .missingInFixture:
            return "Missing in Mock Fixture (Present in Live Wire)"
        case .extraInFixture:
            return "Deprecated / Extra in Mock Fixture (Absent in Live Wire)"
        case .typeMismatch:
            return "Data Type Mismatch"
        case .nullabilityMismatch:
            return "Nullability Mismatch"
        case .statusCodeMismatch:
            return "HTTP Status Code Mismatch"
        }
    }
}

/// A specific field-level drift violation between a Mocker mock fixture and wire traffic.
struct MockerDriftViolation: Sendable, Codable, Equatable, Identifiable {
    var id: String { "\(keyPath)_\(kind.rawValue)" }
    let keyPath: String
    let kind: MockerDriftKind
    let message: String
    let fixtureValue: String?
    let wireValue: String?

    init(
        keyPath: String,
        kind: MockerDriftKind,
        message: String,
        fixtureValue: String? = nil,
        wireValue: String? = nil
    ) {
        self.keyPath = keyPath
        self.kind = kind
        self.message = message
        self.fixtureValue = fixtureValue
        self.wireValue = wireValue
    }
}

/// The diagnostic report summarizing contract drift between a Mocker fixture and production wire traffic.
struct MockerDriftReport: Sendable, Codable, Equatable {
    let isCompliant: Bool
    let violations: [MockerDriftViolation]
    let checkedAt: Date
    let summary: String

    init(
        violations: [MockerDriftViolation],
        checkedAt: Date = Date()
    ) {
        self.violations = violations
        self.isCompliant = violations.isEmpty
        self.checkedAt = checkedAt

        if violations.isEmpty {
            self.summary = "Mocker fixture is 100% synchronized with live wire traffic."
        } else {
            let missingCount = violations.filter { $0.kind == .missingInFixture }.count
            let extraCount = violations.filter { $0.kind == .extraInFixture }.count
            let typeCount = violations.filter { $0.kind == .typeMismatch }.count
            self.summary = "Found \(violations.count) drift issues: \(missingCount) missing in mock, \(extraCount) obsolete in mock, \(typeCount) type mismatches."
        }
    }
}

/// Drift validation engine comparing static Mocker mock JSON fixtures with live wire JSON responses.
struct MockerDriftValidator: Sendable {

    /// Validates a Mocker fixture JSON data against a captured wire response JSON data.
    static func validate(
        fixtureData: Data,
        wireData: Data,
        fixtureStatusCode: Int? = nil,
        wireStatusCode: Int? = nil
    ) -> MockerDriftReport {
        var violations: [MockerDriftViolation] = []

        if let fixtureStatusCode, let wireStatusCode, fixtureStatusCode != wireStatusCode {
            violations.append(MockerDriftViolation(
                keyPath: "$status",
                kind: .statusCodeMismatch,
                message: "Mock status code \(fixtureStatusCode) does not match live wire status code \(wireStatusCode)",
                fixtureValue: "\(fixtureStatusCode)",
                wireValue: "\(wireStatusCode)"
            ))
        }

        guard let fixtureObj = try? JSONSerialization.jsonObject(with: fixtureData),
              let wireObj = try? JSONSerialization.jsonObject(with: wireData) else {
            if fixtureData != wireData {
                violations.append(MockerDriftViolation(
                    keyPath: "$root",
                    kind: .typeMismatch,
                    message: "Payloads are not valid matching JSON or have byte differences."
                ))
            }
            return MockerDriftReport(violations: violations)
        }

        diffJSON(fixture: fixtureObj, wire: wireObj, currentPath: "$", violations: &violations)
        return MockerDriftReport(violations: violations)
    }

    // MARK: - Recursive JSON Diffing

    private static func diffJSON(
        fixture: Any,
        wire: Any,
        currentPath: String,
        violations: inout [MockerDriftViolation]
    ) {
        if let fixtureDict = fixture as? [String: Any], let wireDict = wire as? [String: Any] {
            let fixtureKeys = Set(fixtureDict.keys)
            let wireKeys = Set(wireDict.keys)

            // Keys in live wire but missing in Mocker fixture
            let missingInFixture = wireKeys.subtracting(fixtureKeys)
            for key in missingInFixture.sorted() {
                let path = "\(currentPath).\(key)"
                let wireVal = wireDict[key] ?? ""
                violations.append(MockerDriftViolation(
                    keyPath: path,
                    kind: .missingInFixture,
                    message: "Property '\(key)' is present in live response but missing in Mocker fixture.",
                    fixtureValue: nil,
                    wireValue: "\(wireVal)"
                ))
            }

            // Keys in Mocker fixture but absent in live wire (deprecated or extra)
            let extraInFixture = fixtureKeys.subtracting(wireKeys)
            for key in extraInFixture.sorted() {
                let path = "\(currentPath).\(key)"
                let fixtureVal = fixtureDict[key] ?? ""
                violations.append(MockerDriftViolation(
                    keyPath: path,
                    kind: .extraInFixture,
                    message: "Property '\(key)' is defined in Mocker fixture but no longer sent in live response.",
                    fixtureValue: "\(fixtureVal)",
                    wireValue: nil
                ))
            }

            // Common keys - check recursive types
            let commonKeys = fixtureKeys.intersection(wireKeys)
            for key in commonKeys.sorted() {
                let path = "\(currentPath).\(key)"
                if let fixtureVal = fixtureDict[key], let wireVal = wireDict[key] {
                    diffJSON(fixture: fixtureVal, wire: wireVal, currentPath: path, violations: &violations)
                }
            }
        } else if let fixtureArray = fixture as? [Any], let wireArray = wire as? [Any] {
            if let firstFixture = fixtureArray.first, let firstWire = wireArray.first {
                diffJSON(fixture: firstFixture, wire: firstWire, currentPath: "\(currentPath)[0]", violations: &violations)
            } else if fixtureArray.isEmpty && !wireArray.isEmpty {
                violations.append(MockerDriftViolation(
                    keyPath: currentPath,
                    kind: .nullabilityMismatch,
                    message: "Mocker fixture has empty array while live wire contains \(wireArray.count) elements.",
                    fixtureValue: "[]",
                    wireValue: "[\(wireArray.count) items]"
                ))
            }
        } else {
            // Primitive comparison
            let fixtureType = typeName(of: fixture)
            let wireType = typeName(of: wire)

            if fixtureType != wireType {
                violations.append(MockerDriftViolation(
                    keyPath: currentPath,
                    kind: .typeMismatch,
                    message: "Data type mismatch at '\(currentPath)': Mocker has \(fixtureType), live wire has \(wireType).",
                    fixtureValue: "\(fixture)",
                    wireValue: "\(wire)"
                ))
            }
        }
    }

    private static func typeName(of value: Any) -> String {
        if value is String {
            return "String"
        } else if value is Bool {
            return "Bool"
        } else if value is NSNumber {
            return "Number"
        } else if value is NSNull {
            return "Null"
        } else if value is [String: Any] {
            return "Object"
        } else if value is [Any] {
            return "Array"
        } else {
            return String(describing: type(of: value))
        }
    }
}
