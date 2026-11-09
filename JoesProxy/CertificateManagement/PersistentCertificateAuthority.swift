import CryptoKit
import Foundation
import Network
import Security
import os

final class PersistentKeychainCertificateStore: CertificateStore {
    private enum Accounts {
        static func certificate(label: String) -> String { "\(label).root.certificate" }
        static func privateKey(label: String) -> String { "\(label).root.private-key" }
    }

    private let keychainHelper: any CertificateKeychainAccessing
    private let service = "com.JoesProxy.CertificateAuthority"
    private let logger = Logger(subsystem: "com.JoesProxyApp.TrustFlow", category: "PersistentKeychainCertificateStore")

    init(keychainHelper: any CertificateKeychainAccessing = KeychainHelper()) {
        self.keychainHelper = keychainHelper
    }

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        logger.info("Trust flow: loading persisted root CA for label '\(label, privacy: .public)'")
        guard let certificateData = keychainHelper.retrieveData(
            service: service,
            account: Accounts.certificate(label: label)
        ) else {
            logger.info("Trust flow: no persisted root CA certificate data found for label '\(label, privacy: .public)'")
            return nil
        }

        let privateKeyData = keychainHelper.retrieveData(
            service: service,
            account: Accounts.privateKey(label: label)
        )

        let identity = RootCertificateIdentity.make(
            certificateData: certificateData,
            label: label,
            privateKeyData: privateKeyData
        )
        logger.info(
            "Trust flow: loaded persisted root CA for label '\(label, privacy: .public)' privateKeyPresent=\(privateKeyData != nil)"
        )
        return identity
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        logger.info("Trust flow: saving persisted root CA for label '\(identity.label, privacy: .public)'")
        try keychainHelper.saveData(
            identity.certificateData,
            service: service,
            account: Accounts.certificate(label: identity.label)
        )

        guard let privateKeyData = identity.privateKeyData else {
            throw CertificateAuthorityError.storageFailed("The root certificate identity is missing private key data.")
        }

        try keychainHelper.saveData(
            privateKeyData,
            service: service,
            account: Accounts.privateKey(label: identity.label)
        )
        logger.info("Trust flow: saved persisted root CA and private key for label '\(identity.label, privacy: .public)'")
    }

    func removeRootCertificate(label: String) throws {
        logger.info("Trust flow: removing persisted root CA material for label '\(label, privacy: .public)'")
        try keychainHelper.deleteData(service: service, account: Accounts.certificate(label: label))
        try keychainHelper.deleteData(service: service, account: Accounts.privateKey(label: label))
        logger.info("Trust flow: removed persisted root CA material for label '\(label, privacy: .public)'")
    }
}

/// Thread-safe box wrapping a cached leaf plus issuer/validity guards (Phase D).
private final class LeafCertificateBox {
    let value: IssuedLeafCertificate
    let issuerFingerprint: String
    let notAfter: Date

    init(value: IssuedLeafCertificate, issuerFingerprint: String, notAfter: Date) {
        self.value = value
        self.issuerFingerprint = issuerFingerprint
        self.notAfter = notAfter
    }
}

final class PersistentCertificateAuthorityProvider: CertificateAuthorityProviding {
    /// Sampled debug logging interval for leaf certificate cache hits (AD-2).
    private static let leafCertCacheHitLogInterval = 100

    private let configuration: AppConfiguration
    private let certificateStore: any CertificateStore
    private let certificateFactory: SwiftCertificateFactory
    private let transportDiagnostics: CaptureTransportDiagnostics?
    private let logger = Logger(subsystem: "com.JoesProxyApp.TrustFlow", category: "PersistentCertificateAuthorityProvider")

    /// Per-host leaf certificate cache. Leaf certs are valid for 7 days; caching per-host
    /// eliminates redundant Keychain reads and P256 keygen for repeated connections to the same host.
    /// `NSCache` is thread-safe and evicts under memory pressure automatically.
    private let leafCertificateCache: NSCache<NSString, LeafCertificateBox> = {
        let cache = NSCache<NSString, LeafCertificateBox>()
        cache.countLimit = 500
        return cache
    }()

    /// In-memory SHA-256 of the active root DER. Used for leaf-cache hits so a warm hit never
    /// reloads Keychain; refreshed whenever the active root is loaded, created, promoted, or cleared.
    private var activeIssuerFingerprint: String?

    init(
        configuration: AppConfiguration,
        certificateStore: any CertificateStore,
        certificateFactory: SwiftCertificateFactory = SwiftCertificateFactory(),
        transportDiagnostics: CaptureTransportDiagnostics? = nil
    ) {
        self.configuration = configuration
        self.certificateStore = certificateStore
        self.certificateFactory = certificateFactory
        self.transportDiagnostics = transportDiagnostics
    }

    func currentRootCertificate() -> RootCertificateIdentity? {
        logger.info("Trust flow: reading current root CA for label '\(self.configuration.certificateLabel, privacy: .public)'")
        guard let identity = certificateStore.loadRootCertificate(label: configuration.certificateLabel) else {
            logger.info("Trust flow: current root CA missing for label '\(self.configuration.certificateLabel, privacy: .public)'")
            activeIssuerFingerprint = nil
            return nil
        }

        guard let privateKeyData = identity.privateKeyData else {
            rememberActiveIssuer(from: identity)
            return identity
        }

        do {
            _ = try certificateFactory.rootPrivateKey(from: privateKeyData)
            logger.info("Trust flow: current root CA is usable for label '\(self.configuration.certificateLabel, privacy: .public)'")
            rememberActiveIssuer(from: identity)
            return identity
        } catch {
            logger.error("Trust flow: current root CA has invalid private key material for label '\(self.configuration.certificateLabel, privacy: .public)'")
            rememberActiveIssuer(from: identity)
            return RootCertificateIdentity(
                label: identity.label,
                subjectSummary: identity.subjectSummary,
                certificateData: identity.certificateData,
                privateKeyData: nil
            )
        }
    }

    func loadOrCreateRootCertificate() throws -> RootCertificateIdentity {
        logger.info("Trust flow: loadOrCreate root CA started for label '\(self.configuration.certificateLabel, privacy: .public)'")
        if let existing = certificateStore.loadRootCertificate(label: configuration.certificateLabel) {
            if let privateKeyData = existing.privateKeyData {
                do {
                    _ = try certificateFactory.rootPrivateKey(from: privateKeyData)
                    logger.info("Trust flow: reusing existing root CA for label '\(self.configuration.certificateLabel, privacy: .public)'")
                    rememberActiveIssuer(from: existing)
                    return existing
                } catch {
                    // Incompatible stored key material is intentionally reset.
                    logger.error("Trust flow: stored root CA private key is incompatible, resetting label '\(self.configuration.certificateLabel, privacy: .public)'")
                    try certificateStore.removeRootCertificate(label: configuration.certificateLabel)
                    activeIssuerFingerprint = nil
                    leafCertificateCache.removeAllObjects()
                }
            } else {
                logger.error("Trust flow: stored root CA is missing private key data, resetting label '\(self.configuration.certificateLabel, privacy: .public)'")
                try certificateStore.removeRootCertificate(label: configuration.certificateLabel)
                activeIssuerFingerprint = nil
                leafCertificateCache.removeAllObjects()
            }
        }

        let identity = try certificateFactory.generateRootIdentity(
            label: configuration.certificateLabel,
            commonName: CertificateNaming.productionRootCA
        )
        try certificateStore.saveRootCertificate(identity)
        rememberActiveIssuer(from: identity)
        logger.info("Trust flow: generated new root CA for label '\(self.configuration.certificateLabel, privacy: .public)'")
        return identity
    }

    func issueLeafCertificate(for host: String) throws -> IssuedLeafCertificate {
        let cacheKey = host as NSString
        let now = Date()

        if let cached = leafCertificateCache.object(forKey: cacheKey),
           let activeIssuerFingerprint,
           cached.issuerFingerprint == activeIssuerFingerprint,
           cached.notAfter > now {
            let hitCount = transportDiagnostics?.recordLeafCertCacheHit() ?? 0
            if hitCount == 1 || hitCount.isMultiple(of: Self.leafCertCacheHitLogInterval) {
                logger.debug(
                    "Trust flow: leaf certificate cache hit #\(hitCount, privacy: .public) for host '\(host, privacy: .public)'"
                )
            }
            return cached.value
        }

        transportDiagnostics?.recordLeafCertCacheMiss()
        logger.debug("Trust flow: issuing leaf certificate for host '\(host, privacy: .public)' using label '\(self.configuration.certificateLabel, privacy: .public)'")

        guard let rootIdentity = certificateStore.loadRootCertificate(label: configuration.certificateLabel),
              let privateKeyData = rootIdentity.privateKeyData else {
            logger.error("Trust flow: cannot issue leaf certificate because root identity is unavailable for label '\(self.configuration.certificateLabel, privacy: .public)'")
            throw CertificateAuthorityError.identityUnavailable
        }

        let issuerFingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: rootIdentity.certificateData)
        rememberActiveIssuerFingerprint(issuerFingerprint)

        let leaf = try certificateFactory.issueLeafCertificate(for: host, signedBy: rootIdentity, rootPrivateKeyData: privateKeyData)
        let annotated = IssuedLeafCertificate(
            host: leaf.host,
            certificateData: leaf.certificateData,
            privateKeyData: leaf.privateKeyData,
            issuerCertificateSHA256Fingerprint: issuerFingerprint
        )
        let notAfter = CertificateIdentityExtraction.notAfter(from: annotated.certificateData) ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        leafCertificateCache.setObject(
            LeafCertificateBox(value: annotated, issuerFingerprint: issuerFingerprint, notAfter: notAfter),
            forKey: cacheKey
        )
        logger.debug("Trust flow: issued and cached leaf certificate for host '\(host, privacy: .public)'")
        return annotated
    }

    /// Clears cached leaves; call inside the same critical section as root promotion (Phase D).
    func invalidateLeafCertificateCache() {
        leafCertificateCache.removeAllObjects()
    }

    /// Clears the in-memory active-issuer fingerprint (e.g. after Reset removes the root).
    func clearActiveIssuerFingerprint() {
        activeIssuerFingerprint = nil
    }

    private func rememberActiveIssuer(from identity: RootCertificateIdentity) {
        rememberActiveIssuerFingerprint(
            CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        )
    }

    private func rememberActiveIssuerFingerprint(_ fingerprint: String) {
        activeIssuerFingerprint = fingerprint
    }

    /// Generates a pending renewal root under a non-colliding Keychain label (Phase D prepare).
    ///
    /// - Parameter pendingLabel: Must differ from the active ``AppConfiguration/certificateLabel``
    ///   so ``PersistentTrustInstaller`` does not treat both roots as duplicate same-label certs.
    func prepareRenewalRoot(pendingLabel: String) throws -> RootCertificateIdentity {
        if let existing = certificateStore.loadRootCertificate(label: pendingLabel),
           existing.privateKeyData != nil {
            return existing
        }
        let identity = try certificateFactory.generateRootIdentity(
            label: pendingLabel,
            commonName: CertificateNaming.productionRootCA
        )
        try certificateStore.saveRootCertificate(identity)
        return identity
    }

    /// Atomically promotes a pending root into the active Keychain label and clears the leaf cache.
    ///
    /// Failure before the active save completes leaves the previous active root unchanged.
    func promoteRenewalRoot(pendingLabel: String) throws -> RootCertificateIdentity {
        guard let pending = certificateStore.loadRootCertificate(label: pendingLabel),
              pending.privateKeyData != nil else {
            throw CertificateAuthorityError.identityUnavailable
        }

        let promoted = RootCertificateIdentity(
            label: configuration.certificateLabel,
            subjectSummary: pending.subjectSummary,
            certificateData: pending.certificateData,
            privateKeyData: pending.privateKeyData
        )
        try certificateStore.saveRootCertificate(promoted)
        rememberActiveIssuer(from: promoted)
        leafCertificateCache.removeAllObjects()
        try? certificateStore.removeRootCertificate(label: pendingLabel)
        return promoted
    }

    /// Keychain label for a pending renewal root that will not collide with the active label detector.
    static func pendingRenewalLabel(baseLabel: String, shortCode: String) -> String {
        let code = shortCode.replacingOccurrences(of: "-", with: "")
        return "\(baseLabel).pending-\(code)"
    }
}

final class PersistentTrustInstaller: TrustInstalling, CertificateFingerprintTrustCleaning {
    private let keychainHelper: any CertificateKeychainAccessing
    private let certificateStore: any CertificateStore
    private let trustEvaluator: any CertificateTrustEvaluating
    private let logger = Logger(subsystem: "com.JoesProxyApp.TrustFlow", category: "PersistentTrustInstaller")

    init(
        keychainHelper: any CertificateKeychainAccessing = KeychainHelper(),
        certificateStore: any CertificateStore = PersistentKeychainCertificateStore(),
        trustEvaluator: any CertificateTrustEvaluating = SystemCertificateTrustEvaluator()
    ) {
        self.keychainHelper = keychainHelper
        self.certificateStore = certificateStore
        self.trustEvaluator = trustEvaluator
    }

    func installationStatus(for label: String) -> TrustInstallationStatus {
        installationStatus(for: label, preloadedIdentity: nil)
    }

    /// Same check, but skips the redundant Keychain load when the caller (e.g.
    /// `PersistentCertificateStatusReader.readStatus()`) has already loaded the root CA identity
    /// in the same refresh — `readStatus()` used to load it once itself and then again in here,
    /// doubling Keychain I/O on every status refresh for no reason.
    func installationStatus(for label: String, preloadedIdentity: RootCertificateIdentity?) -> TrustInstallationStatus {
        logger.info("Trust flow: evaluating installation status for label '\(label, privacy: .public)'")
        let installedCertificates: [SecCertificate]
        do {
            installedCertificates = try keychainHelper.retrieveCertificates(withLabel: label)
            guard !installedCertificates.isEmpty else {
                logger.info("Trust flow: no installed root CA found in keychain for label '\(label, privacy: .public)'")
                return .notInstalled
            }
        } catch {
            logger.error("Trust flow: keychain lookup failed while evaluating label '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return .invalid(reason: error.localizedDescription)
        }

        guard let currentIdentity = preloadedIdentity ?? certificateStore.loadRootCertificate(label: label) else {
            logger.error("Trust flow: installed certificate(s) exist but no persisted root CA material exists for label '\(label, privacy: .public)'")
            return .invalid(reason: "A '\(label)' certificate is installed, but JoesProxy has no matching persisted CA material. Reset Certificate State before creating a new root CA.")
        }

        let matchingCertificates = installedCertificates.filter {
            SecCertificateCopyData($0) as Data == currentIdentity.certificateData
        }
        let staleCertificates = installedCertificates.filter {
            SecCertificateCopyData($0) as Data != currentIdentity.certificateData
        }

        if matchingCertificates.isEmpty {
            logger.error("Trust flow: installed certificate(s) do not match persisted root CA for label '\(label, privacy: .public)'")
            return .invalid(reason: "Installed '\(label)' certificates do not match the current JoesProxy root CA. Reset Certificate State to clean up stale certificates.")
        }

        if matchingCertificates.count > 1 || !staleCertificates.isEmpty {
            logger.error("Trust flow: duplicate or stale certificates detected for label '\(label, privacy: .public)' matching=\(matchingCertificates.count) stale=\(staleCertificates.count)")
            return .invalid(reason: "Multiple '\(label)' certificates are installed. Reset Certificate State to remove stale or duplicate certificates.")
        }

        let status = trustEvaluator.installationStatus(for: matchingCertificates[0])
        logger.info("Trust flow: trust evaluator returned \(String(describing: status), privacy: .public) for label '\(label, privacy: .public)'")
        return status
    }

    func install(_ identity: RootCertificateIdentity) throws {
        logger.info("Trust flow: installing root CA into keychain for label '\(identity.label, privacy: .public)'")
        guard let certificate = SecCertificateCreateWithData(nil, identity.certificateData as CFData) else {
            logger.error("Trust flow: failed to reconstruct certificate data for install label '\(identity.label, privacy: .public)'")
            throw CertificateAuthorityError.generationFailed("Could not reconstruct the root certificate for trust installation.")
        }

        let existingCertificates = try keychainHelper.retrieveCertificates(withLabel: identity.label)
        let exactExistingMatches = existingCertificates.filter {
            SecCertificateCopyData($0) as Data == identity.certificateData
        }
        let staleExistingCertificates = existingCertificates.filter {
            SecCertificateCopyData($0) as Data != identity.certificateData
        }

        if staleExistingCertificates.isEmpty, exactExistingMatches.count == 1 {
            logger.info("Trust flow: exact matching installed certificate already exists for label '\(identity.label, privacy: .public)'")
            return
        }

        if !existingCertificates.isEmpty {
            logger.info("Trust flow: deleting \(existingCertificates.count) existing certificate(s) before install for label '\(identity.label, privacy: .public)'")
            for existingCertificate in existingCertificates {
                try keychainHelper.deleteCertificate(existingCertificate, label: identity.label)
            }
        }

        try keychainHelper.addCertificate(certificate, label: identity.label)
        logger.info("Trust flow: keychain add completed for label '\(identity.label, privacy: .public)', verifying readback")

        let installedCertificates = try keychainHelper.retrieveCertificates(withLabel: identity.label)
        guard !installedCertificates.isEmpty else {
            logger.error("Trust flow: keychain add succeeded but readback failed for label '\(identity.label, privacy: .public)'")
            throw CertificateAuthorityError.trustInstallationFailed(
                """
                The root CA was added, but JoesProxy could not read it back from the keychain. \
                The certificate may have been stored outside the app's expected keychain access group or rejected by the current keychain configuration.
                """
            )
        }

        let exactMatches = installedCertificates.filter {
            SecCertificateCopyData($0) as Data == identity.certificateData
        }
        let staleCertificates = installedCertificates.filter {
            SecCertificateCopyData($0) as Data != identity.certificateData
        }

        guard exactMatches.count == 1, staleCertificates.isEmpty else {
            logger.error("Trust flow: readback certificate mismatch or duplicates after install for label '\(identity.label, privacy: .public)' matches=\(exactMatches.count) stale=\(staleCertificates.count)")
            throw CertificateAuthorityError.trustInstallationFailed(
                "Installed certificates for '\(identity.label)' do not uniquely match the current JoesProxy root CA. Reset Certificate State to clear stale or duplicate certificates."
            )
        }

        logger.info("Trust flow: install verification succeeded for label '\(identity.label, privacy: .public)'")
    }

    func removeCertificate(label: String) throws {
        logger.info("Trust flow: removing root CA from keychain for label '\(label, privacy: .public)'")
        let installedCertificates = try keychainHelper.retrieveCertificates(withLabel: label)
        guard !installedCertificates.isEmpty else {
            if certificateStore.loadRootCertificate(label: label) != nil {
                logger.error("Trust flow: persisted root CA exists but keychain item is missing during remove for label '\(label, privacy: .public)'")
                throw CertificateAuthorityError.trustRemovalFailed(
                    "JoesProxy has stored root CA material for '\(label)', but no matching installed certificate was found in the keychain to remove."
                )
            }
            logger.info("Trust flow: nothing to remove from keychain for label '\(label, privacy: .public)'")
            return
        }

        logger.info("Trust flow: deleting \(installedCertificates.count) installed certificate(s) for label '\(label, privacy: .public)'")
        for certificate in installedCertificates {
            try keychainHelper.deleteCertificate(certificate, label: label)
        }
        logger.info("Trust flow: keychain delete completed for label '\(label, privacy: .public)', verifying removal")

        if !(try keychainHelper.retrieveCertificates(withLabel: label)).isEmpty {
            logger.error("Trust flow: certificate still visible after removal for label '\(label, privacy: .public)'")
            throw CertificateAuthorityError.trustRemovalFailed(
                "One or more '\(label)' certificates still appear in the keychain after removal was requested."
            )
        }

        logger.info("Trust flow: removal verification succeeded for label '\(label, privacy: .public)'")
    }

    /// Removes only installed trust certificates whose DER SHA-256 matches `fingerprint`.
    ///
    /// Unlike ``removeCertificate(label:)``, this never deletes unrelated certificates that share
    /// the generic JoesProxy label (e.g. another Mac's still-valid root).
    @discardableResult
    func removeInstalledCertificate(matchingFingerprint fingerprint: String, label: String) throws -> Int {
        let normalized = fingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        let installedCertificates = try keychainHelper.retrieveCertificates(withLabel: label)
        let matches = installedCertificates.filter { certificate in
            let data = SecCertificateCopyData(certificate) as Data
            return CertificateIdentityExtraction.sha256Fingerprint(from: data) == normalized
        }
        guard !matches.isEmpty else {
            logger.info(
                "Trust flow: no installed certificate matched fingerprint cleanup for label '\(label, privacy: .public)'"
            )
            return 0
        }
        for certificate in matches {
            try keychainHelper.deleteCertificate(certificate, label: label)
        }
        logger.info(
            "Trust flow: removed \(matches.count) fingerprint-matched installed certificate(s) for label '\(label, privacy: .public)'"
        )
        return matches.count
    }
}

final class IOSDeviceTrustProfileExporter: IOSDeviceTrustProfileExporting {
    private enum Constants {
        static let organization = "JoesProxy"
        static let certificatePayloadType = "com.apple.security.root"
        static let configurationPayloadType = "Configuration"
    }

    private let configuration: AppConfiguration
    private let certificateAuthority: any CertificateAuthorityProviding
    /// Optional CA metadata for stable payload identifiers (Phase B). Read on the calling thread.
    var caInstanceMetadataProvider: (() -> CAInstanceMetadata?)?
    /// Optional distribution recorder; invoked on the main actor after a successful export build.
    var distributionRecorder: (@MainActor (CertificateDistributionRecord) throws -> Void)?

    init(
        configuration: AppConfiguration,
        certificateAuthority: any CertificateAuthorityProviding
    ) {
        self.configuration = configuration
        self.certificateAuthority = certificateAuthority
    }

    func exportTrustProfile(to destinationURL: URL) throws {
        let identity = try certificateAuthority.loadOrCreateRootCertificate()
        let built = try buildProfileData(for: identity)
        try built.data.write(to: destinationURL, options: .atomic)
        if let record = built.distributionRecord, let distributionRecorder {
            Task { @MainActor in
                try? distributionRecorder(record)
            }
        }
    }

    private struct BuiltProfile {
        let data: Data
        let distributionRecord: CertificateDistributionRecord?
    }

    private func buildProfileData(for identity: RootCertificateIdentity) throws -> BuiltProfile {
        let certificatePayloadUUID = UUID().uuidString
        let profilePayloadUUID = UUID().uuidString
        let artifactID = UUID()
        let metadata = caInstanceMetadataProvider?()
        let notAfter = CertificateIdentityExtraction.notAfter(from: identity.certificateData)
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        let serial = CertificateIdentityExtraction.serialNumber(from: identity.certificateData)

        let certificateIdentifier: String
        let profileIdentifier: String
        let displayName: String
        let profileDescription: String
        let certificateDisplayName: String
        let certificateDescription: String
        var distributionRecord: CertificateDistributionRecord?

        if let metadata {
            let shortCode = metadata.shortCode
            profileIdentifier = CertificateProfilePayloadIdentity.profilePayloadIdentifier(
                shortCode: shortCode,
                artifactID: artifactID
            )
            certificateIdentifier = "com.showblender.joesproxy.ca.\(shortCode.replacingOccurrences(of: "-", with: "").lowercased()).certificate.\(certificatePayloadUUID.lowercased())"
            displayName = CertificateProfilePayloadIdentity.displayName(shortCode: shortCode, notAfter: notAfter)
            profileDescription = CertificateProfilePayloadIdentity.description(
                shortCode: shortCode,
                notAfter: notAfter,
                platform: "iPhone or iPad"
            )
            certificateDisplayName = displayName
            certificateDescription = profileDescription
            distributionRecord = CertificateDistributionRecord(
                artifactID: artifactID,
                caInstanceID: metadata.id,
                shortCode: shortCode,
                certificateSHA256Fingerprint: fingerprint,
                certificateSerialNumber: serial ?? metadata.certificateSerialNumber,
                certificateNotAfter: notAfter ?? metadata.notAfter,
                profileKind: .iosTrustProfile,
                payloadIdentifier: profileIdentifier,
                resolvedHost: nil,
                proxyPort: nil,
                userNickname: metadata.nickname,
                generatedAt: Date(),
                appVersion: Bundle.main.marketingVersionOrDev,
                status: .generated
            )
        } else {
            certificateIdentifier = "com.showblender.joesproxy.certificate.\(certificatePayloadUUID.lowercased())"
            profileIdentifier = "com.showblender.joesproxy.ios.profile.\(profilePayloadUUID.lowercased())"
            displayName = "\(Constants.organization) iOS Trust Profile"
            profileDescription = "Installs the \(configuration.certificateLabel) root certificate authority on iPhone or iPad."
            certificateDisplayName = identity.label
            certificateDescription = "Installs the \(identity.label) root certificate authority for HTTPS inspection."
        }

        let certificatePayload: [String: Any] = [
            "PayloadCertificateFileName": "\(identity.label).cer",
            "PayloadContent": identity.certificateData,
            "PayloadDescription": certificateDescription,
            "PayloadDisplayName": certificateDisplayName,
            "PayloadIdentifier": certificateIdentifier,
            "PayloadOrganization": Constants.organization,
            "PayloadType": Constants.certificatePayloadType,
            "PayloadUUID": certificatePayloadUUID,
            "PayloadVersion": 1
        ]

        let profile: [String: Any] = [
            "PayloadContent": [certificatePayload],
            "PayloadDescription": profileDescription,
            "PayloadDisplayName": displayName,
            "PayloadIdentifier": profileIdentifier,
            "PayloadOrganization": Constants.organization,
            "PayloadRemovalDisallowed": false,
            "PayloadType": Constants.configurationPayloadType,
            "PayloadUUID": profilePayloadUUID,
            "PayloadVersion": 1
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: profile,
                format: .xml,
                options: 0
            )
            return BuiltProfile(data: data, distributionRecord: distributionRecord)
        } catch {
            throw CertificateAuthorityError.generationFailed("Could not generate the iOS trust profile.")
        }
    }
}

final class TVOSManagedProfileExporter: TVOSManagedProfileExporting {
    private enum Constants {
        static let organization = "JoesProxy"
        static let proxyPayloadType = "com.apple.proxy.http.global"
        static let certificatePayloadType = "com.apple.security.root"
        static let configurationPayloadType = "Configuration"
    }

    private let configuration: AppConfiguration
    private let certificateAuthority: any CertificateAuthorityProviding
    var caInstanceMetadataProvider: (() -> CAInstanceMetadata?)?
    var distributionRecorder: (@MainActor (CertificateDistributionRecord) throws -> Void)?

    init(configuration: AppConfiguration, certificateAuthority: any CertificateAuthorityProviding) {
        self.configuration = configuration
        self.certificateAuthority = certificateAuthority
    }

    func exportManagedProfile(to destinationURL: URL, host: String, port: Int) throws {
        let identity = try certificateAuthority.loadOrCreateRootCertificate()
        let built = try buildProfileData(for: identity, host: host, port: port)
        try built.data.write(to: destinationURL, options: .atomic)
        if let record = built.distributionRecord, let distributionRecorder {
            Task { @MainActor in
                try? distributionRecorder(record)
            }
        }
    }

    private struct BuiltProfile {
        let data: Data
        let distributionRecord: CertificateDistributionRecord?
    }

    private func buildProfileData(for identity: RootCertificateIdentity, host: String, port: Int) throws -> BuiltProfile {
        let proxyPayloadUUID = UUID().uuidString
        let certificatePayloadUUID = UUID().uuidString
        let profilePayloadUUID = UUID().uuidString
        let artifactID = UUID()
        let metadata = caInstanceMetadataProvider?()
        let notAfter = CertificateIdentityExtraction.notAfter(from: identity.certificateData)
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        let serial = CertificateIdentityExtraction.serialNumber(from: identity.certificateData)

        let profileIdentifier: String
        let displayName: String
        let profileDescription: String
        let certificateDisplayName: String
        let certificateDescription: String
        var distributionRecord: CertificateDistributionRecord?

        if let metadata {
            let shortCode = metadata.shortCode
            profileIdentifier = CertificateProfilePayloadIdentity.profilePayloadIdentifier(
                shortCode: shortCode,
                artifactID: artifactID
            )
            displayName = CertificateProfilePayloadIdentity.displayName(shortCode: shortCode, notAfter: notAfter)
            profileDescription = CertificateProfilePayloadIdentity.description(
                shortCode: shortCode,
                notAfter: notAfter,
                platform: "Apple TV"
            )
            certificateDisplayName = displayName
            certificateDescription = profileDescription
            distributionRecord = CertificateDistributionRecord(
                artifactID: artifactID,
                caInstanceID: metadata.id,
                shortCode: shortCode,
                certificateSHA256Fingerprint: fingerprint,
                certificateSerialNumber: serial ?? metadata.certificateSerialNumber,
                certificateNotAfter: notAfter ?? metadata.notAfter,
                profileKind: .tvOSManagedProxyProfile,
                payloadIdentifier: profileIdentifier,
                resolvedHost: host,
                proxyPort: UInt16(clamping: port),
                userNickname: metadata.nickname,
                generatedAt: Date(),
                appVersion: Bundle.main.marketingVersionOrDev,
                status: .generated
            )
        } else {
            profileIdentifier = "com.showblender.joesproxy.appletv.managed.\(profilePayloadUUID.lowercased())"
            displayName = "JoesProxy Apple TV Proxy Profile"
            profileDescription = "Configures global HTTP proxy and installs JoesProxy CA for HTTPS inspection on Apple TV."
            certificateDisplayName = identity.label
            certificateDescription = "Installs the \(identity.label) root certificate authority for HTTPS inspection."
        }

        let proxyPayload: [String: Any] = [
            "PayloadType": Constants.proxyPayloadType,
            "PayloadDisplayName": "Global HTTP Proxy",
            "PayloadDescription": "Routes traffic through JoesProxy for HTTPS inspection.",
            "PayloadIdentifier": "com.showblender.joesproxy.proxy.\(proxyPayloadUUID.lowercased())",
            "PayloadOrganization": Constants.organization,
            "PayloadUUID": proxyPayloadUUID,
            "PayloadVersion": 1,
            "ProxyType": "Manual",
            "ProxyServer": host,
            "ProxyServerPort": port,
            "ProxyCaptiveLoginAllowed": false
        ]

        let certificatePayload: [String: Any] = [
            "PayloadCertificateFileName": "\(identity.label).cer",
            "PayloadContent": identity.certificateData,
            "PayloadDescription": certificateDescription,
            "PayloadDisplayName": certificateDisplayName,
            "PayloadIdentifier": metadata.map {
                "com.showblender.joesproxy.ca.\($0.shortCode.replacingOccurrences(of: "-", with: "").lowercased()).certificate.\(certificatePayloadUUID.lowercased())"
            } ?? "com.showblender.joesproxy.certificate.\(certificatePayloadUUID.lowercased())",
            "PayloadOrganization": Constants.organization,
            "PayloadType": Constants.certificatePayloadType,
            "PayloadUUID": certificatePayloadUUID,
            "PayloadVersion": 1
        ]

        let profile: [String: Any] = [
            "PayloadContent": [proxyPayload, certificatePayload],
            "PayloadDescription": profileDescription,
            "PayloadDisplayName": displayName,
            "PayloadIdentifier": profileIdentifier,
            "PayloadOrganization": Constants.organization,
            "PayloadRemovalDisallowed": false,
            "PayloadType": Constants.configurationPayloadType,
            "PayloadUUID": profilePayloadUUID,
            "PayloadVersion": 1
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            return BuiltProfile(data: data, distributionRecord: distributionRecord)
        } catch {
            throw CertificateAuthorityError.generationFailed("Could not generate the Apple TV managed proxy profile.")
        }
    }
}

struct SystemCertificateTrustEvaluator: CertificateTrustEvaluating {
    private let logger = Logger(subsystem: "com.JoesProxyApp.TrustFlow", category: "SystemCertificateTrustEvaluator")

    func installationStatus(for certificate: SecCertificate) -> TrustInstallationStatus {
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)

        guard status == errSecSuccess, let trust else {
            logger.error("Trust flow: SecTrustCreateWithCertificates failed with status \(status)")
            return .invalid(reason: "The installed certificate could not be evaluated.")
        }

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            logger.info("Trust flow: SecTrustEvaluateWithError succeeded")
            return .installed
        }

        let message = (error as Error?)?.localizedDescription ?? "The installed root certificate failed trust evaluation."
        logger.error("Trust flow: SecTrustEvaluateWithError failed: \(message, privacy: .public)")
        return .trustRequired(reason: message)
    }
}

/// Performs lifecycle certificate checks away from the main actor. Keychain and trust evaluation
/// can block unpredictably, so they must not run while SwiftUI is constructing or activating the
/// main window.
actor PersistentCertificateStatusReader: CertificateStatusReading {
    private let label: String
    private let certificateStore: PersistentKeychainCertificateStore
    private let trustInstaller: PersistentTrustInstaller
    private let certificateFactory = SwiftCertificateFactory()
    private let logger = Logger(subsystem: "com.JoesProxyApp.TrustFlow", category: "CertificateStatusReader")

    init(label: String) {
        self.label = label
        let certificateStore = PersistentKeychainCertificateStore()
        self.certificateStore = certificateStore
        self.trustInstaller = PersistentTrustInstaller(certificateStore: certificateStore)
    }

    func readStatus() async -> CertificateStatusSnapshot {
        let startedAt = Date()
        let rootCertificate = validatedRootCertificate()
        let trustStatus = trustInstaller.installationStatus(for: label, preloadedIdentity: rootCertificate)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        logger.info("Trust flow: background status refresh completed in \(elapsedMilliseconds, privacy: .public) ms")
        return CertificateStatusSnapshot(rootCertificate: rootCertificate, trustStatus: trustStatus)
    }

    private func validatedRootCertificate() -> RootCertificateIdentity? {
        guard let identity = certificateStore.loadRootCertificate(label: label) else { return nil }
        guard let privateKeyData = identity.privateKeyData else { return identity }
        do {
            _ = try certificateFactory.rootPrivateKey(from: privateKeyData)
            return identity
        } catch {
            return RootCertificateIdentity(
                label: identity.label,
                subjectSummary: identity.subjectSummary,
                certificateData: identity.certificateData,
                privateKeyData: nil
            )
        }
    }
}

struct SwiftCertificateFactory: Sendable {
    private let rootValidityInterval: TimeInterval = 5 * 365 * 24 * 60 * 60
    private let leafValidityInterval: TimeInterval = 7 * 24 * 60 * 60

    func generateRootIdentity(label: String, commonName: String) throws -> RootCertificateIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let subject = DistinguishedName(
            countryName: "US",
            organizationName: "JoesProxy",
            organizationalUnitName: "Certificate Authority",
            commonName: commonName
        )
        let certificate = try makeRootCertificate(subject: subject, privateKey: privateKey)

        return RootCertificateIdentity(
            label: label,
            subjectSummary: commonName,
            certificateData: certificate.derEncoded,
            privateKeyData: privateKey.rawRepresentation
        )
    }

    func issueLeafCertificate(
        for host: String,
        signedBy rootIdentity: RootCertificateIdentity,
        rootPrivateKeyData: Data
    ) throws -> IssuedLeafCertificate {
        guard !host.isEmpty else {
            throw CertificateAuthorityError.invalidHost(host)
        }

        let rootPrivateKey = try rootPrivateKey(from: rootPrivateKeyData)
        let leafPrivateKey = P256.Signing.PrivateKey()
        let issuer = DistinguishedName(
            countryName: "US",
            organizationName: "JoesProxy",
            organizationalUnitName: "Certificate Authority",
            commonName: rootIdentity.subjectSummary
        )
        let issuerKeyIdentifier = subjectKeyIdentifier(for: rootPrivateKey.publicKey.x963Representation)
        let leafCertificate = try makeLeafCertificate(
            host: host,
            issuer: issuer,
            issuerPrivateKey: rootPrivateKey,
            issuerKeyIdentifier: issuerKeyIdentifier,
            leafPrivateKey: leafPrivateKey
        )

        return IssuedLeafCertificate(
            host: host,
            certificateData: leafCertificate.derEncoded,
            privateKeyData: try exportLeafPrivateKeyPEM(leafPrivateKey)
        )
    }

    func rootPrivateKey(from data: Data) throws -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw CertificateAuthorityError.generationFailed("The stored root private key could not be decoded by the native certificate backend.")
        }
    }

    private func makeRootCertificate(
        subject: DistinguishedName,
        privateKey: P256.Signing.PrivateKey
    ) throws -> EncodedCertificate {
        let subjectKeyIdentifier = subjectKeyIdentifier(for: privateKey.publicKey.x963Representation)
        let now = Date()

        return try makeCertificate(
            serialNumber: randomSerialNumber(),
            issuer: subject,
            subject: subject,
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(rootValidityInterval),
            publicKey: privateKey.publicKey.x963Representation,
            extensions: [
                .basicConstraints(isCA: true, maxPathLength: 0, critical: true),
                .keyUsage(
                    digitalSignature: true,
                    keyEncipherment: false,
                    keyCertSign: true,
                    cRLSign: true,
                    critical: true
                ),
                .extendedKeyUsage([.serverAuth, .clientAuth]),
                .subjectKeyIdentifier(subjectKeyIdentifier),
                .authorityKeyIdentifier(subjectKeyIdentifier)
            ],
            signer: privateKey
        )
    }

    private func makeLeafCertificate(
        host: String,
        issuer: DistinguishedName,
        issuerPrivateKey: P256.Signing.PrivateKey,
        issuerKeyIdentifier: Data,
        leafPrivateKey: P256.Signing.PrivateKey
    ) throws -> EncodedCertificate {
        let subject = DistinguishedName(
            countryName: "US",
            organizationName: "JoesProxy",
            organizationalUnitName: "MITM Leaf",
            commonName: host
        )
        let subjectKeyIdentifier = subjectKeyIdentifier(for: leafPrivateKey.publicKey.x963Representation)
        let subjectAlternativeName = makeSubjectAlternativeNames(for: host)
        let now = Date()

        return try makeCertificate(
            serialNumber: randomSerialNumber(),
            issuer: issuer,
            subject: subject,
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(leafValidityInterval),
            publicKey: leafPrivateKey.publicKey.x963Representation,
            extensions: [
                .basicConstraints(isCA: false, maxPathLength: nil, critical: true),
                .keyUsage(
                    digitalSignature: true,
                    keyEncipherment: true,
                    keyCertSign: false,
                    cRLSign: false,
                    critical: true
                ),
                .extendedKeyUsage([.serverAuth]),
                .subjectAlternativeNames(subjectAlternativeName),
                .subjectKeyIdentifier(subjectKeyIdentifier),
                .authorityKeyIdentifier(issuerKeyIdentifier)
            ],
            signer: issuerPrivateKey
        )
    }

    private func makeCertificate(
        serialNumber: Data,
        issuer: DistinguishedName,
        subject: DistinguishedName,
        notValidBefore: Date,
        notValidAfter: Date,
        publicKey: Data,
        extensions: [CertificateExtension],
        signer: P256.Signing.PrivateKey
    ) throws -> EncodedCertificate {
        let subjectPublicKeyInfo = subjectPublicKeyInfo(publicKey: publicKey)
        let tbsCertificate = derSequence([
            derExplicit(tagNumber: 0, value: derInteger(2)),
            derInteger(serialNumber),
            signatureAlgorithmIdentifier(),
            issuer.derEncoded,
            validity(notValidBefore: notValidBefore, notValidAfter: notValidAfter),
            subject.derEncoded,
            subjectPublicKeyInfo,
            derExplicit(tagNumber: 3, value: derSequence(extensions.map(\.derEncoded)))
        ])
        let signature = try signer.signature(for: tbsCertificate).derRepresentation
        let certificate = derSequence([
            tbsCertificate,
            signatureAlgorithmIdentifier(),
            derBitString(signature)
        ])

        return EncodedCertificate(derEncoded: certificate)
    }

    private func exportLeafPrivateKeyPEM(_ privateKey: P256.Signing.PrivateKey) throws -> Data {
        let pemString = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey.rawRepresentation).pemRepresentation
        return Data(pemString.utf8)
    }

    private func makeSubjectAlternativeNames(for host: String) -> [SubjectAlternativeName] {
        if let ipv4Address = IPv4Address(host) {
            return [.ipAddress(Data(ipv4Address.rawValue))]
        }

        if let ipv6Address = IPv6Address(host) {
            return [.ipAddress(Data(ipv6Address.rawValue))]
        }

        return [.dnsName(host)]
    }

    private func subjectKeyIdentifier(for publicKey: Data) -> Data {
        Data(Insecure.SHA1.hash(data: publicKey))
    }
}

private struct EncodedCertificate: Sendable {
    let derEncoded: Data
}

/// Distinguished name used by the hand-rolled DER encoder.
///
/// Phase B4 spike (deferred): this type currently encodes a **single** OU RDN. Adding a second
/// subject OU (e.g. `OU=JoesProxy Instance 7K4M-2Q9P`) also requires ``SwiftCertificateFactory``
/// leaf issuance to carry the full root subject into the leaf `issuer` DN — today the leaf issuer
/// is reconstructed from constants + common name only. Do not add a second OU until that path is
/// fixed and validated on macOS / iOS / iPadOS / tvOS / Simulator.
private struct DistinguishedName: Sendable {
    let countryName: String
    let organizationName: String
    /// Single OU today. Phase B4 spike: a second instance OU requires leaf issuer DN to carry
    /// the full root subject (not reconstruct from CN + hardcoded OU) or chain validation fails.
    let organizationalUnitName: String
    let commonName: String

    var derEncoded: Data {
        derSequence([
            relativeDistinguishedName(oid: [0x55, 0x04, 0x06], value: countryName, stringTag: 0x13),
            relativeDistinguishedName(oid: [0x55, 0x04, 0x0A], value: organizationName, stringTag: 0x0C),
            relativeDistinguishedName(oid: [0x55, 0x04, 0x0B], value: organizationalUnitName, stringTag: 0x0C),
            relativeDistinguishedName(oid: [0x55, 0x04, 0x03], value: commonName, stringTag: 0x0C)
        ])
    }
}

private enum EnhancedKeyUsageOID: Sendable {
    case serverAuth
    case clientAuth

    var bytes: [UInt8] {
        switch self {
        case .serverAuth:
            return [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
        case .clientAuth:
            return [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]
        }
    }
}

private enum SubjectAlternativeName: Sendable {
    case dnsName(String)
    case ipAddress(Data)
}

private enum CertificateExtension: Sendable {
    case basicConstraints(isCA: Bool, maxPathLength: Int?, critical: Bool)
    case keyUsage(digitalSignature: Bool, keyEncipherment: Bool, keyCertSign: Bool, cRLSign: Bool, critical: Bool)
    case extendedKeyUsage([EnhancedKeyUsageOID])
    case subjectAlternativeNames([SubjectAlternativeName])
    case subjectKeyIdentifier(Data)
    case authorityKeyIdentifier(Data)

    var derEncoded: Data {
        switch self {
        case .basicConstraints(let isCA, let maxPathLength, let critical):
            let value = basicConstraintsValue(isCA: isCA, maxPathLength: maxPathLength)
            return encodedExtension(oid: [0x55, 0x1D, 0x13], critical: critical, value: value)
        case .keyUsage(let digitalSignature, let keyEncipherment, let keyCertSign, let cRLSign, let critical):
            let value = keyUsageValue(
                digitalSignature: digitalSignature,
                keyEncipherment: keyEncipherment,
                keyCertSign: keyCertSign,
                cRLSign: cRLSign
            )
            return encodedExtension(oid: [0x55, 0x1D, 0x0F], critical: critical, value: value)
        case .extendedKeyUsage(let usages):
            let value = derSequence(usages.map { derObjectIdentifier($0.bytes) })
            return encodedExtension(oid: [0x55, 0x1D, 0x25], critical: false, value: value)
        case .subjectAlternativeNames(let names):
            let value = derSequence(names.map(\.derEncoded))
            return encodedExtension(oid: [0x55, 0x1D, 0x11], critical: false, value: value)
        case .subjectKeyIdentifier(let identifier):
            let value = derOctetString(identifier)
            return encodedExtension(oid: [0x55, 0x1D, 0x0E], critical: false, value: value)
        case .authorityKeyIdentifier(let identifier):
            let value = derSequence([derTaggedPrimitive(tag: 0x80, value: identifier)])
            return encodedExtension(oid: [0x55, 0x1D, 0x23], critical: false, value: value)
        }
    }
}

private extension SubjectAlternativeName {
    var derEncoded: Data {
        switch self {
        case .dnsName(let host):
            return derTaggedPrimitive(tag: 0x82, value: Data(host.utf8))
        case .ipAddress(let address):
            return derTaggedPrimitive(tag: 0x87, value: address)
        }
    }
}

private func relativeDistinguishedName(oid: [UInt8], value: String, stringTag: UInt8) -> Data {
    derSet([
        derSequence([
            derObjectIdentifier(oid),
            derTagged(tag: stringTag, value: Data(value.utf8))
        ])
    ])
}

private func encodedExtension(oid: [UInt8], critical: Bool, value: Data) -> Data {
    var fields = [derObjectIdentifier(oid)]
    if critical {
        fields.append(derBoolean(true))
    }
    fields.append(derOctetString(value))
    return derSequence(fields)
}

private func basicConstraintsValue(isCA: Bool, maxPathLength: Int?) -> Data {
    var elements: [Data] = []
    if isCA {
        elements.append(derBoolean(true))
    }
    if let maxPathLength {
        elements.append(derInteger(maxPathLength))
    }
    return derSequence(elements)
}

private func keyUsageValue(
    digitalSignature: Bool,
    keyEncipherment: Bool,
    keyCertSign: Bool,
    cRLSign: Bool
) -> Data {
    var bitIndices: [Int] = []
    if digitalSignature {
        bitIndices.append(0)
    }
    if keyEncipherment {
        bitIndices.append(2)
    }
    if keyCertSign {
        bitIndices.append(5)
    }
    if cRLSign {
        bitIndices.append(6)
    }

    guard let highestBit = bitIndices.max() else {
        return derRaw(tag: 0x03, value: Data([0x00]))
    }

    let byteCount = (highestBit / 8) + 1
    var bytes = [UInt8](repeating: 0, count: byteCount)

    for bitIndex in bitIndices {
        let byteIndex = bitIndex / 8
        let shift = 7 - (bitIndex % 8)
        bytes[byteIndex] |= UInt8(1 << shift)
    }

    let usedBitsInLastByte = (highestBit % 8) + 1
    let unusedBits = UInt8((8 - usedBitsInLastByte) % 8)
    return derRaw(tag: 0x03, value: Data([unusedBits] + bytes))
}

private func subjectPublicKeyInfo(publicKey: Data) -> Data {
    derSequence([
        derSequence([
            derObjectIdentifier([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
            derObjectIdentifier([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        ]),
        derBitString(publicKey)
    ])
}

private func signatureAlgorithmIdentifier() -> Data {
    derSequence([
        derObjectIdentifier([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    ])
}

private func validity(notValidBefore: Date, notValidAfter: Date) -> Data {
    derSequence([
        derUTCTime(notValidBefore),
        derUTCTime(notValidAfter)
    ])
}

private func randomSerialNumber() -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
        bytes = Array(UUID().uuidString.utf8.prefix(16))
    }

    bytes[0] &= 0x7F
    if bytes[0] == 0 {
        bytes[0] = 1
    }

    return Data(bytes)
}

private func derSequence(_ values: [Data]) -> Data {
    derConstructed(tag: 0x30, children: values)
}

private func derSet(_ values: [Data]) -> Data {
    derConstructed(tag: 0x31, children: values)
}

private func derExplicit(tagNumber: UInt8, value: Data) -> Data {
    derConstructed(tag: 0xA0 | tagNumber, children: [value])
}

private func derObjectIdentifier(_ bytes: [UInt8]) -> Data {
    derRaw(tag: 0x06, value: Data(bytes))
}

private func derBoolean(_ value: Bool) -> Data {
    derRaw(tag: 0x01, value: Data([value ? 0xFF : 0x00]))
}

private func derInteger(_ value: Int) -> Data {
    derInteger(Data(integerBytes(value)))
}

private func derInteger(_ data: Data) -> Data {
    var bytes = [UInt8](data)
    while bytes.count > 1, bytes.first == 0, bytes[1] < 0x80 {
        bytes.removeFirst()
    }
    if let first = bytes.first, first >= 0x80 {
        bytes.insert(0, at: 0)
    }
    return derRaw(tag: 0x02, value: Data(bytes))
}

private func derOctetString(_ value: Data) -> Data {
    derRaw(tag: 0x04, value: value)
}

private func derBitString(_ value: Data) -> Data {
    derRaw(tag: 0x03, value: Data([0x00]) + value)
}

private func derTaggedPrimitive(tag: UInt8, value: Data) -> Data {
    derRaw(tag: tag, value: value)
}

private func derTagged(tag: UInt8, value: Data) -> Data {
    derRaw(tag: tag, value: value)
}

/// Shared DER UTCTime formatter. `DateFormatter` is expensive to allocate; this is
/// reused across all certificate issuances. Access is confined to the NIO event loop
/// thread (single-threaded) and the main thread (root cert operations), but `DateFormatter`
/// is not thread-safe for concurrent access. Since these call sites do not overlap on the
/// same thread simultaneously this is safe in practice; if that changes, use a lock.
private let derUTCTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    return formatter
}()

private func derUTCTime(_ date: Date) -> Data {
    derRaw(tag: 0x17, value: Data(derUTCTimeFormatter.string(from: date).utf8))
}

private func derConstructed(tag: UInt8, children: [Data]) -> Data {
    derRaw(tag: tag, value: children.reduce(into: Data(), { $0.append($1) }))
}

private func derRaw(tag: UInt8, value: Data) -> Data {
    var data = Data([tag])
    data.append(derLength(value.count))
    data.append(value)
    return data
}

private func derLength(_ length: Int) -> Data {
    precondition(length >= 0)

    if length < 0x80 {
        return Data([UInt8(length)])
    }

    let bytes = integerBytes(length)
    return Data([0x80 | UInt8(bytes.count)] + bytes)
}

private func integerBytes(_ value: Int) -> [UInt8] {
    var remaining = value
    var bytes: [UInt8] = []

    repeat {
        bytes.insert(UInt8(remaining & 0xFF), at: 0)
        remaining >>= 8
    } while remaining > 0

    return bytes
}

private extension RootCertificateIdentity {
    static func make(certificateData: Data, label: String, privateKeyData: Data?) -> RootCertificateIdentity {
        let subjectSummary: String

        if let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
           let summary = SecCertificateCopySubjectSummary(certificate) as String? {
            subjectSummary = summary
        } else {
            subjectSummary = label
        }

        return RootCertificateIdentity(
            label: label,
            subjectSummary: subjectSummary,
            certificateData: certificateData,
            privateKeyData: privateKeyData
        )
    }
}
