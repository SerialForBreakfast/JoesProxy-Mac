//
//  KeychainHelper.swift
//  JoesProxy
//
//  Created by Joseph McCraw on 11/5/24.
//

import Foundation
import Security
import os

final class KeychainHelper: CertificateKeychainAccessing {
    private enum QueryOperation {
        case add
        case delete
        case copyMatching
    }

    private let logger = Logger(subsystem: "com.JoesProxyApp.CertificateManagement", category: "KeychainHelper")
    private let additionalQueryAttributes: [String: Any]
    private let keychainOverride: SecKeychain?

    init(
        additionalQueryAttributes: [String: Any] = [:],
        keychainOverride: SecKeychain? = nil
    ) {
        self.additionalQueryAttributes = additionalQueryAttributes
        self.keychainOverride = keychainOverride
    }

    private func mergedQueryAttributes(
        _ query: [String: Any],
        operation: QueryOperation
    ) -> [String: Any] {
        let itemClass = query[kSecClass as String] as? String
        let appliesAccessGroup = itemClass != (kSecClassCertificate as String)

        var merged = query
            .merging(appliesAccessGroup ? KeychainAccessGroup.queryAttribute() : [:]) { current, _ in current }
            .merging(additionalQueryAttributes) { _, override in override }

        if let keychainOverride {
            merged[kSecUseKeychain as String] = keychainOverride
            merged[kSecMatchSearchList as String] = [keychainOverride]
        }

        return merged
    }

    func addCertificate(_ certificate: SecCertificate, label: String) throws {
        logger.info("Attempting to add certificate to keychain with label: \(label)")
        let accessGroup = KeychainAccessGroup.current
        logger.info("Resolved keychain access group: \(accessGroup ?? "default")")
        logger.info("No implicit certificate deletion is performed before add for label '\(label)'.")

        // Add the new certificate to the keychain
        let addQuery = mergedQueryAttributes([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true
        ], operation: .add)

        logger.info("Add Query Attributes:")
        addQuery.forEach { key, value in
            logger.info("  \(key): \(String(describing: value))")
        }
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        
        if status != errSecSuccess && status != errSecDuplicateItem {
            logger.error("Failed to add certificate to keychain. Status: \(status) - \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown")")
            throw CertificateError.installationFailed
        }

        logger.info("Certificate added to keychain successfully.")
    }

    func deleteCertificate(_ certificate: SecCertificate, label: String) throws {
        logger.info("Attempting to delete certificate from keychain with label: \(label)")
        let accessGroup = KeychainAccessGroup.current
        logger.info("Resolved keychain access group: \(accessGroup ?? "default")")

        let deleteQuery = mergedQueryAttributes([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label
        ], operation: .delete)

        logger.info("Delete Query Attributes:")
        deleteQuery.forEach { key, value in
            logger.info("  \(key): \(String(describing: value))")
        }
        
        let status = SecItemDelete(deleteQuery as CFDictionary)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Failed to delete certificate from keychain. Status: \(status) - \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown")")
            throw CertificateError.removalFailed
        }

        logger.info("Certificate deleted from keychain successfully.")
    }

    func retrieveCertificate(withLabel label: String) throws -> SecCertificate? {
        try retrieveCertificates(withLabel: label).first
    }

    func retrieveCertificates(withLabel label: String) throws -> [SecCertificate] {
        logger.info("Retrieving certificate with label: \(label)")
        let accessGroup = KeychainAccessGroup.current
        logger.info("Resolved keychain access group: \(accessGroup ?? "default")")

        let query = mergedQueryAttributes([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ], operation: .copyMatching)

        logger.info("Retrieve Query Attributes:")
        query.forEach { key, value in
            logger.info("  \(key): \(String(describing: value))")
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess {
            if let certificates = item as? [SecCertificate] {
                logger.info("Found \(certificates.count) certificate(s) with label \(label).")
                return certificates
            }

            logger.info("Found 1 certificate with label \(label).")
            return [item as! SecCertificate]
        }

        if status == errSecItemNotFound {
            logger.info("Certificate with label \(label) not found. Status: \(status) - \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown")")
            return []
        }

        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown keychain error"
        logger.error("Failed to retrieve certificate with label \(label). Status: \(status) - \(message)")
        throw CertificateAuthorityError.keychainAccessFailed(
            "Keychain lookup failed for '\(label)' with status \(status): \(message)."
        )
    }

    func listAllCertificates() {
        let accessGroup = KeychainAccessGroup.current
        let query = mergedQueryAttributes([
            kSecClass as String: kSecClassCertificate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ], operation: .copyMatching)

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        if status == errSecSuccess, let certArray = items as? [SecCertificate] {
            logger.info("Listing all certificates in Keychain Access Group '\(accessGroup ?? "default")':")
            for (index, cert) in certArray.enumerated() {
                if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                    logger.info("  Certificate \(index + 1): \(summary)")
                }
            }
        } else {
            logger.info("No certificates found in Keychain Access Group '\(accessGroup ?? "default")'.")
        }
    }

    func saveData(_ data: Data, service: String, account: String) throws {
        let deleteQuery = mergedQueryAttributes([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ], operation: .delete)

        let _ = SecItemDelete(deleteQuery as CFDictionary)

        let addQuery = mergedQueryAttributes([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ], operation: .add)

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Failed to save keychain data for service '\(service)' account '\(account)'. Status: \(status)")
            throw CertificateAuthorityError.storageFailed("Failed to persist certificate key material.")
        }
    }

    func retrieveData(service: String, account: String) -> Data? {
        let query = mergedQueryAttributes([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ], operation: .copyMatching)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }

        return item as? Data
    }

    func deleteData(service: String, account: String) throws {
        let query = mergedQueryAttributes([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ], operation: .delete)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete keychain data for service '\(service)' account '\(account)'. Status: \(status)")
            throw CertificateAuthorityError.storageFailed("Failed to remove persisted certificate key material.")
        }
    }
}
