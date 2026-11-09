import Foundation
import Security

enum KeychainAccessGroup {
    private static let entitlementKey = "keychain-access-groups" as CFString

    static var current: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let entitlementValue = SecTaskCopyValueForEntitlement(task, entitlementKey, nil) else {
            return nil
        }

        if let groups = entitlementValue as? [String] {
            return groups.first
        }

        if CFGetTypeID(entitlementValue) == CFArrayGetTypeID(),
           let groups = entitlementValue as? [String] {
            return groups.first
        }

        return nil
    }

    static func queryAttribute() -> [String: Any] {
        guard let current else {
            return [:]
        }

        return [kSecAttrAccessGroup as String: current]
    }
}
