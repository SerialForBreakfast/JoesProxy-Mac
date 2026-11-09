//
//  CertificateError.swift
//  JoesProxy
//
//  Created by Joseph McCraw on 11/5/24.
//
// SSLProxyApp/Modules/CertificateManagement/CertificateError.swift

enum CertificateError: Error {
    case generationFailed
    case installationFailed
    case removalFailed
    case validationFailed
    case certificateNotFound
}
