import Foundation

/// Coarse failure buckets used for user-facing copy and optional session metadata.
///
/// Reachability / path monitoring (`NWPathMonitor`, etc.) is intentionally **not** used in v1.
/// ``probableNoConnectivity`` is assigned only when a concrete operation error (for example
/// `URLError.notConnectedToInternet`) already signals that condition.
enum NetworkFailureBucket: String, Codable, Sendable, CaseIterable {
    case dnsFailure
    case refusedConnection
    case timeout
    case tlsCertificate
    case probableNoConnectivity
    case incompleteResponse
    case localProxyStart
    case invalidRequest
    case certificateSetup
    case connectionFailed
    case fileAccess
    case unknown

    /// Short label for inspector section headers and diagnostics.
    var displayTitle: String {
        switch self {
        case .dnsFailure:
            return "DNS Lookup Failed"
        case .refusedConnection:
            return "Connection Refused"
        case .timeout:
            return "Connection Timed Out"
        case .tlsCertificate:
            return "TLS Or Certificate Problem"
        case .probableNoConnectivity:
            return "Network Unavailable"
        case .incompleteResponse:
            return "Incomplete Upstream Response"
        case .localProxyStart:
            return "Proxy Start Problem"
        case .invalidRequest:
            return "Invalid Request"
        case .certificateSetup:
            return "Certificate Setup Problem"
        case .connectionFailed:
            return "Connection Failed"
        case .fileAccess:
            return "File Access Problem"
        case .unknown:
            return "Failure"
        }
    }
}

/// Where a failure is surfaced so copy can mention the right recovery steps.
enum UserFacingErrorSurface: Sendable {
    case network
    case fileExport
    case profileServer
}

/// Product-ready explanation for a transport or proxy failure.
struct NetworkFailurePresentation: Equatable, Sendable {
    let bucket: NetworkFailureBucket
    let title: String
    let message: String
    let recoveryHint: String?
    /// Original error text retained for logs and optional detail surfaces.
    let technicalDetail: String?

    /// Primary string shown in banners, bookmark failures, and session failure rows.
    var userFacingMessage: String {
        guard let recoveryHint, !recoveryHint.isEmpty else {
            return message
        }
        return "\(message)\n\n\(recoveryHint)"
    }
}

/// Maps concrete `Error` values from NIO, URLSession, POSIX, and app layers into
/// stable user-facing buckets with recovery guidance.
enum NetworkFailureClassifier {
    /// Classifies a preformatted failure string (for example legacy test fixtures).
    static func presentation(forMessage message: String) -> NetworkFailurePresentation {
        presentationFromDescription(message)
    }

    /// Convenience for call sites that only need the combined user-facing string.
    static func userFacingMessage(for error: Error, surface: UserFacingErrorSurface = .network) -> String {
        presentation(for: error, surface: surface).userFacingMessage
    }

    static func presentation(for error: Error, surface: UserFacingErrorSurface = .network) -> NetworkFailurePresentation {
        if let surfacePresentation = presentationForSurface(error, surface: surface) {
            return surfacePresentation
        }
        return presentationForNetwork(error)
    }

    private static func presentationForNetwork(_ error: Error) -> NetworkFailurePresentation {
        if let presentation = presentationForKnownAppError(error) {
            return presentation
        }

        if let urlError = error as? URLError {
            return presentation(for: urlError)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return presentation(
                for: URLError.Code(rawValue: nsError.code),
                technicalDetail: error.localizedDescription
            )
        }

        if nsError.domain == NSPOSIXErrorDomain {
            return presentation(forPOSIXCode: nsError.code, technicalDetail: error.localizedDescription)
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let underlyingPresentation = presentationForNetwork(underlying)
            if underlyingPresentation.bucket != .unknown {
                return underlyingPresentation.enrichingTechnicalDetailIfNeeded(error.localizedDescription)
            }
        }

        return presentationFromDescription(error.localizedDescription)
    }

    private static func presentationForSurface(
        _ error: Error,
        surface: UserFacingErrorSurface
    ) -> NetworkFailurePresentation? {
        switch surface {
        case .network:
            return nil
        case .fileExport:
            return presentationForFileExport(error)
        case .profileServer:
            return presentationForProfileServer(error)
        }
    }

    private static func presentationForFileExport(_ error: Error) -> NetworkFailurePresentation? {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 4, 260:
                return NetworkFailurePresentation(
                    bucket: .fileAccess,
                    title: "File Not Found",
                    message: "JoesProxy could not find the selected file or folder.",
                    recoveryHint: "Choose another destination or confirm the path still exists.",
                    technicalDetail: error.localizedDescription
                )
            case 512, 513, 257:
                return fileAccessPresentation(
                    message: "JoesProxy does not have permission to write the selected file.",
                    technicalDetail: error.localizedDescription
                )
            default:
                break
            }
        }

        let normalized = error.localizedDescription.lowercased()
        if normalized.contains("permission") || normalized.contains("not permitted") {
            return fileAccessPresentation(
                message: "JoesProxy does not have permission to write the selected file.",
                technicalDetail: error.localizedDescription
            )
        }

        if normalized.contains("no space") || normalized.contains("disk full") {
            return NetworkFailurePresentation(
                bucket: .fileAccess,
                title: "Disk Full",
                message: "There is not enough free space to save the export.",
                recoveryHint: "Free disk space or choose another destination, then try again.",
                technicalDetail: error.localizedDescription
            )
        }

        return nil
    }

    private static func presentationForProfileServer(_ error: Error) -> NetworkFailurePresentation? {
        if let serverError = error as? ProfileHostingServer.ServerError {
            switch serverError {
            case .bindFailed(let reason):
                let normalized = reason.lowercased()
                if normalized.contains("already in use") {
                    return NetworkFailurePresentation(
                        bucket: .localProxyStart,
                        title: "Profile Server Port In Use",
                        message: "The profile download server could not start because port 8765 is already in use.",
                        recoveryHint: "Quit the other app using that port, or restart JoesProxy, then reopen this walkthrough.",
                        technicalDetail: reason
                    )
                }
                return NetworkFailurePresentation(
                    bucket: .localProxyStart,
                    title: "Profile Server Failed",
                    message: "The certificate profile server could not start on your local network.",
                    recoveryHint: "Confirm macOS allows incoming connections for JoesProxy, then reopen this walkthrough.",
                    technicalDetail: reason
                )
            }
        }

        return nil
    }

    // MARK: - App errors

    private static func presentationForKnownAppError(_ error: Error) -> NetworkFailurePresentation? {
        switch error {
        case let bookmarkError as BookmarkExecutionError:
            return presentation(for: bookmarkError)
        case let proxyError as ProxyError:
            return presentation(for: proxyError)
        case let connectorError as HTTPUpstreamConnectorError:
            return presentation(for: connectorError)
        case is CertificateAuthorityError:
            return certificateSetupPresentation(
                message: error.localizedDescription,
                technicalDetail: error.localizedDescription
            )
        case let networkIOError as NetworkConnectionIOError:
            return presentation(for: networkIOError)
        default:
            return nil
        }
    }

    private static func presentation(for error: BookmarkExecutionError) -> NetworkFailurePresentation {
        switch error {
        case .invalidRequestURL:
            return NetworkFailurePresentation(
                bucket: .invalidRequest,
                title: "Invalid Bookmark Request",
                message: "The bookmark request URL could not be built from the captured request.",
                recoveryHint: "Open the bookmark editor and fix the host, path, or scheme, then try again.",
                technicalDetail: nil
            )
        case .invalidRequest(let message):
            return NetworkFailurePresentation(
                bucket: .invalidRequest,
                title: "Invalid Bookmark Request",
                message: message,
                recoveryHint: "Update the bookmark request fields before running it again.",
                technicalDetail: nil
            )
        case .timedOut:
            return timeoutPresentation(technicalDetail: nil)
        case .networkFailure(let message):
            return presentationFromDescription(message)
        }
    }

    private static func presentation(for error: ProxyError) -> NetworkFailurePresentation {
        switch error {
        case .invalidPort:
            return NetworkFailurePresentation(
                bucket: .localProxyStart,
                title: "Invalid Proxy Port",
                message: error.localizedDescription,
                recoveryHint: "Open Settings, choose a port between 1 and 65535, then tap Retry.",
                technicalDetail: nil
            )
        case .startFailed(let reason):
            if reason.localizedCaseInsensitiveContains("already in use") {
                return localProxyPortInUsePresentation(portDetail: reason, technicalDetail: reason)
            }
            return presentationFromDescription(reason)
        case .listenerCreationFailed:
            return NetworkFailurePresentation(
                bucket: .localProxyStart,
                title: "Proxy Listener Failed",
                message: "JoesProxy could not open a listener for incoming proxy traffic.",
                recoveryHint: "Try a different port in Settings. If the problem continues, restart JoesProxy.",
                technicalDetail: error.localizedDescription
            )
        case .stopFailed:
            return NetworkFailurePresentation(
                bucket: .connectionFailed,
                title: "Proxy Stop Failed",
                message: "JoesProxy could not stop the proxy cleanly.",
                recoveryHint: "Try stopping the proxy again. Restart the app if it remains stuck.",
                technicalDetail: error.localizedDescription
            )
        case .connectionFailed:
            return connectionFailedPresentation(technicalDetail: error.localizedDescription)
        }
    }

    private static func presentation(for error: HTTPUpstreamConnectorError) -> NetworkFailurePresentation {
        switch error {
        case .invalidPort(let port):
            return NetworkFailurePresentation(
                bucket: .invalidRequest,
                title: "Invalid Upstream Port",
                message: "The upstream port \(port) is not valid for forwarding.",
                recoveryHint: "Check the captured host and port, or adjust any Map Remote rule targeting this request.",
                technicalDetail: error.localizedDescription
            )
        case .tlsConfigurationFailed(let message):
            return tlsCertificatePresentation(message: message, technicalDetail: error.localizedDescription)
        case .incompleteResponse:
            return NetworkFailurePresentation(
                bucket: .incompleteResponse,
                title: "Incomplete Upstream Response",
                message: "The upstream server closed the connection before sending a complete HTTP response.",
                recoveryHint: "Retry the request. If it keeps failing, inspect upstream logs or try the call outside the proxy.",
                technicalDetail: error.localizedDescription
            )
        }
    }

    private static func presentation(for error: NetworkConnectionIOError) -> NetworkFailurePresentation {
        switch error {
        case .failedToStart(let message), .receiveFailed(let message), .sendFailed(let message):
            return presentationFromDescription(message)
        case .connectionClosed:
            return NetworkFailurePresentation(
                bucket: .incompleteResponse,
                title: "Connection Closed",
                message: error.localizedDescription,
                recoveryHint: "Retry the operation after confirming the proxy and destination remain reachable.",
                technicalDetail: error.localizedDescription
            )
        }
    }

    // MARK: - URLError

    private static func presentation(for error: URLError) -> NetworkFailurePresentation {
        presentation(for: error.code, technicalDetail: error.localizedDescription)
    }

    private static func presentation(
        for code: URLError.Code,
        technicalDetail: String?
    ) -> NetworkFailurePresentation {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return probableNoConnectivityPresentation(technicalDetail: technicalDetail)
        case .cannotFindHost, .dnsLookupFailed:
            return dnsFailurePresentation(technicalDetail: technicalDetail)
        case .cannotConnectToHost:
            return refusedConnectionPresentation(technicalDetail: technicalDetail)
        case .timedOut:
            return timeoutPresentation(technicalDetail: technicalDetail)
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .clientCertificateRejected,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRequired:
            return tlsCertificatePresentation(
                message: "The TLS handshake could not be completed for this connection.",
                technicalDetail: technicalDetail
            )
        default:
            return presentationFromDescription(technicalDetail ?? "The network request failed.")
        }
    }

    // MARK: - POSIX

    private static func presentation(
        forPOSIXCode code: Int,
        technicalDetail: String?
    ) -> NetworkFailurePresentation {
        switch code {
        case 60, 45:
            return timeoutPresentation(technicalDetail: technicalDetail)
        case 61:
            return refusedConnectionPresentation(technicalDetail: technicalDetail)
        case 64, 65:
            return dnsFailurePresentation(technicalDetail: technicalDetail)
        case 50, 51, 52:
            return probableNoConnectivityPresentation(technicalDetail: technicalDetail)
        default:
            return presentationFromDescription(technicalDetail ?? "The connection failed.")
        }
    }

    // MARK: - Description heuristics

    private static func presentationFromDescription(_ description: String) -> NetworkFailurePresentation {
        let normalized = description.lowercased()

        if normalized.contains("address already in use") {
            return localProxyPortInUsePresentation(portDetail: description, technicalDetail: description)
        }

        if normalized.contains("timed out") || normalized.contains("timeout") {
            return timeoutPresentation(technicalDetail: description)
        }

        if normalized.contains("could not find host")
            || normalized.contains("nodename nor servname")
            || normalized.contains("dns")
            || normalized.contains("hostname could not be found") {
            return dnsFailurePresentation(technicalDetail: description)
        }

        if normalized.contains("connection refused")
            || normalized.contains("errno = 61")
            || normalized.contains("nioconnectionerror")
            || normalized.contains("connection reset")
            || normalized.contains("broken pipe") {
            return refusedConnectionPresentation(technicalDetail: description)
        }

        if normalized.contains("not connected to internet")
            || normalized.contains("network is down")
            || normalized.contains("network is unreachable")
            || normalized.contains("no route to host")
            || normalized.contains("errno = 50")
            || normalized.contains("errno = 51") {
            return probableNoConnectivityPresentation(technicalDetail: description)
        }

        if normalized.contains("certificate")
            || normalized.contains("tls")
            || normalized.contains("ssl")
            || normalized.contains("handshake")
            || normalized.contains("trust") {
            return tlsCertificatePresentation(message: description, technicalDetail: description)
        }

        if normalized.contains("incomplete response")
            || normalized.contains("closed the connection before") {
            return NetworkFailurePresentation(
                bucket: .incompleteResponse,
                title: "Incomplete Upstream Response",
                message: "The upstream server closed the connection before sending a complete HTTP response.",
                recoveryHint: "Retry the request or inspect upstream server behavior.",
                technicalDetail: description
            )
        }

        if normalized.contains("certificate authority")
            || normalized.contains("root certificate")
            || normalized.contains("keychain") {
            return certificateSetupPresentation(message: description, technicalDetail: description)
        }

        if normalized.contains("bad request") || normalized.contains("invalid port") {
            return NetworkFailurePresentation(
                bucket: .invalidRequest,
                title: "Invalid Request",
                message: description,
                recoveryHint: "Check the request URL, method, and headers, then try again.",
                technicalDetail: description
            )
        }

        return NetworkFailurePresentation(
            bucket: .unknown,
            title: "Connection Failed",
            message: "JoesProxy could not complete this connection.",
            recoveryHint: "Verify the host and port, confirm the proxy is running, and check that your Mac still has network access.",
            technicalDetail: description
        )
    }

    // MARK: - Bucket copy

    private static func dnsFailurePresentation(technicalDetail: String?) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .dnsFailure,
            title: "DNS Lookup Failed",
            message: "JoesProxy could not resolve the upstream hostname.",
            recoveryHint: "Check the hostname spelling, VPN or DNS settings, and whether the service is reachable from this Mac.",
            technicalDetail: technicalDetail
        )
    }

    private static func refusedConnectionPresentation(technicalDetail: String?) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .refusedConnection,
            title: "Connection Refused",
            message: "The upstream host refused the connection.",
            recoveryHint: "Confirm the service is running, the port is correct, and any firewall allows traffic from this Mac.",
            technicalDetail: technicalDetail
        )
    }

    private static func timeoutPresentation(technicalDetail: String?) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .timeout,
            title: "Connection Timed Out",
            message: "The upstream host did not respond in time.",
            recoveryHint: "Retry the request, confirm the service is healthy, and check VPN or network latency.",
            technicalDetail: technicalDetail
        )
    }

    private static func tlsCertificatePresentation(
        message: String,
        technicalDetail: String?
    ) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .tlsCertificate,
            title: "TLS Or Certificate Problem",
            message: message,
            recoveryHint: "For HTTPS inspection, confirm the JoesProxy root CA is installed and trusted. For upstream TLS errors, verify the server certificate and hostname.",
            technicalDetail: technicalDetail
        )
    }

    private static func probableNoConnectivityPresentation(technicalDetail: String?) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .probableNoConnectivity,
            title: "Network Unavailable",
            message: "This Mac does not appear to have a working network connection for the request.",
            recoveryHint: "Check Wi‑Fi or Ethernet, VPN status, and captive portals, then retry.",
            technicalDetail: technicalDetail
        )
    }

    private static func fileAccessPresentation(
        message: String,
        technicalDetail: String?
    ) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .fileAccess,
            title: "File Access Problem",
            message: message,
            recoveryHint: "Try another destination or verify JoesProxy still has permission to write the selected file.",
            technicalDetail: technicalDetail
        )
    }

    private static func connectionFailedPresentation(technicalDetail: String?) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .connectionFailed,
            title: "Connection Failed",
            message: "JoesProxy could not complete the upstream connection.",
            recoveryHint: "Verify the destination host and port, then retry once the service is reachable.",
            technicalDetail: technicalDetail
        )
    }

    private static func certificateSetupPresentation(
        message: String,
        technicalDetail: String?
    ) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .certificateSetup,
            title: "Certificate Setup Problem",
            message: message,
            recoveryHint: "Open Certificate Setup or Guided Setup & Repair to install or trust the JoesProxy root CA.",
            technicalDetail: technicalDetail
        )
    }

    private static func localProxyPortInUsePresentation(
        portDetail: String,
        technicalDetail: String?
    ) -> NetworkFailurePresentation {
        NetworkFailurePresentation(
            bucket: .localProxyStart,
            title: "Proxy Port In Use",
            message: portDetail,
            recoveryHint: "Change the port in Settings, then tap Retry.",
            technicalDetail: technicalDetail
        )
    }
}

private extension NetworkFailurePresentation {
    func enrichingTechnicalDetailIfNeeded(_ detail: String) -> NetworkFailurePresentation {
        guard technicalDetail == nil else {
            return self
        }
        return NetworkFailurePresentation(
            bucket: bucket,
            title: title,
            message: message,
            recoveryHint: recoveryHint,
            technicalDetail: detail
        )
    }
}
