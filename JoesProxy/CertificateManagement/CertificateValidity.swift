import Foundation
import Security

/// Parses X.509 validity dates (notBefore / notAfter) from a DER-encoded certificate.
enum CertificateValidity {
    /// Returns the validity window for a DER certificate, or nil if it cannot be parsed.
    static func dates(fromDER data: Data) -> (notBefore: Date, notAfter: Date)? {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            return nil
        }

        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any] else {
            return nil
        }

        guard
            let notBefore = absoluteTimeDate(in: values, key: kSecOIDX509V1ValidityNotBefore),
            let notAfter = absoluteTimeDate(in: values, key: kSecOIDX509V1ValidityNotAfter)
        else {
            return nil
        }

        return (notBefore, notAfter)
    }

    /// Extracts a date stored as a CFAbsoluteTime number under a values dictionary key.
    private static func absoluteTimeDate(in values: [CFString: Any], key: CFString) -> Date? {
        guard
            let entry = values[key] as? [CFString: Any],
            let number = entry[kSecPropertyKeyValue] as? NSNumber
        else {
            return nil
        }
        // SecCertificateCopyValues reports validity as CFAbsoluteTime (seconds since 2001-01-01).
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }
}
