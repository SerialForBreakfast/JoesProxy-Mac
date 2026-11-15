import Foundation

/// Retain the signing material if the installed root cannot be identified or removed.
enum CertificateRetirement {
    enum Failure: LocalizedError {
        case installed(Error), stored(Error), stillStored

        var errorDescription: String? {
            switch self {
            case .installed(let error): "Stored identity retained. \(error.localizedDescription)"
            case .stored(let error): "Signing identity retirement could not be verified. \(error.localizedDescription)"
            case .stillStored: "The signing identity is still present after deletion."
            }
        }
    }

    static func run(readFingerprint: () throws -> String?,
                    removeInstalled: (String?) throws -> Void,
                    removeStored: () throws -> Void) throws -> String? {
        let fingerprint: String?
        do {
            fingerprint = try readFingerprint()
            try removeInstalled(fingerprint)
        } catch { throw Failure.installed(error) }
        do {
            try removeStored()
            guard try readFingerprint() == nil else { throw Failure.stillStored }
        } catch { throw Failure.stored(error) }
        return fingerprint
    }
}
