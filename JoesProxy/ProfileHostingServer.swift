//
//  ProfileHostingServer.swift
//  JoesProxy
//
//  On-demand HTTP server that serves the root CA certificate and iOS trust profile over the
//  local network. Intended to run only while a device setup walkthrough is presented.
//
//  Lifecycle:
//  - start(port:) — binds on 0.0.0.0:<port> via NWListener, resolves the LAN-reachable URL
//  - stop()       — cancels the listener, releases the port, clears serverURL
//
//  Endpoints:
//  - GET /                    → HTML landing page with download links
//  - GET /profile.mobileconfig → .mobileconfig trust profile (application/x-apple-aspen-config),
//                                served with an explicit Content-Disposition filename so a
//                                browser/OS that falls back to extension-based recognition (no
//                                Safari-specific download interception, e.g. Chrome on iOS) still
//                                saves a correctly-named, correctly-typed .mobileconfig file.
//  - GET /profile              → same response as /profile.mobileconfig; kept for backward
//                                compatibility with anything that already links the bare path.
//  - GET /cert                → DER root certificate bytes (application/x-x509-ca-cert)
//

import Foundation
import Network
import os

/// An on-demand HTTP server that serves the JoesProxy root CA certificate and iOS trust profile
/// over the local network.
///
/// Create one instance, call ``start(port:)`` when the device setup walkthrough opens, and
/// ``stop()`` when the walkthrough is dismissed. ``serverURL`` reflects the reachable base URL
/// while the server is running.
///
/// The server uses a simple HTTP/1.0-style model: one request per connection, no keep-alive.
/// This is appropriate for file download from Safari on a local network.
actor ProfileHostingServer {

    // MARK: - Errors

    enum ServerError: LocalizedError {
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .bindFailed(let reason):
                return "Profile server could not start: \(reason)"
            }
        }
    }

    // MARK: - Properties

    /// The base URL for the running server, e.g. `http://192.168.1.5:8765`.
    /// `nil` when the server is not running.
    private(set) var serverURL: URL?

    private let certificateAuthority: any CertificateAuthorityProviding
    private let profileExporter: any IOSDeviceTrustProfileExporting
    private var listener: NWListener?
    private let logger = Logger(subsystem: "com.JoesProxyApp.ProfileServer", category: "ProfileHostingServer")

    /// Called once when the trust profile is successfully served (first request only).
    /// Invoked from within the actor's isolation; dispatch to MainActor in the handler if needed.
    private var profileServedHandler: (@Sendable () -> Void)?

    func setProfileServedHandler(_ handler: @escaping @Sendable () -> Void) {
        profileServedHandler = handler
    }

    // MARK: - Init

    init(
        certificateAuthority: any CertificateAuthorityProviding,
        profileExporter: any IOSDeviceTrustProfileExporting
    ) {
        self.certificateAuthority = certificateAuthority
        self.profileExporter = profileExporter
    }

    // MARK: - Lifecycle

    /// Starts the profile server on the given port, binding to all local interfaces.
    ///
    /// If the server is already running this is a no-op. Calling `start` again after `stop`
    /// is safe.
    ///
    /// - Parameter port: TCP port. Defaults to 8765 to avoid conflict with the proxy listener.
    /// - Throws: ``ServerError/bindFailed(_:)`` if the port cannot be acquired.
    func start(port: UInt16 = 8765, host: String? = nil) async throws {
        guard listener == nil else {
            logger.info("Profile server start requested but already running on port \(port)")
            return
        }

        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.bindFailed("Invalid port \(port)")
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: .tcp, on: networkPort)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }

        let networkInfo = LocalNetworkInfo.current()
        let resolvedHost = host ?? networkInfo.bonjourName ?? networkInfo.lanIP ?? "127.0.0.1"
        serverURL = URL(string: "http://\(resolvedHost):\(port)")

        newListener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleConnection(connection)
            }
        }

        newListener.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.listenerDidChangeState(state)
            }
        }

        newListener.start(queue: .global(qos: .utility))
        listener = newListener
        logger.info("Profile server started — \(self.serverURL?.absoluteString ?? "(unknown URL)")")
    }

    /// Stops the profile server and releases the port.
    func stop() {
        listener?.cancel()
        listener = nil
        serverURL = nil
        logger.info("Profile server stopped")
    }

    // MARK: - Listener State

    private func listenerDidChangeState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            logger.error("Profile server listener failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            serverURL = nil
        case .cancelled:
            listener = nil
            serverURL = nil
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        let requestData = await receiveData(from: connection)
        let requestText = String(data: requestData, encoding: .utf8) ?? ""
        let path = extractPath(from: requestText)
        logger.debug("Profile server: request path '\(path)'")
        let response = buildResponse(for: path)
        await send(response, on: connection)
        connection.cancel()
    }

    private func receiveData(from connection: NWConnection) async -> Data {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    // MARK: - Request Parsing

    private func extractPath(from request: String) -> String {
        // First line of an HTTP request is "METHOD /path HTTP/version"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              firstLine.contains(" ") else {
            return "/"
        }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return "/" }
        // Strip query string
        let rawPath = parts[1]
        return rawPath.components(separatedBy: "?").first ?? rawPath
    }

    // MARK: - Response Building

    private func buildResponse(for path: String) -> Data {
        switch path {
        case "/profile.mobileconfig", "/profile":
            return profileResponse()
        case "/cert":
            return certResponse()
        default:
            return landingPageResponse()
        }
    }

    private func profileResponse() -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-profile-\(UUID().uuidString)")
            .appendingPathExtension("mobileconfig")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try profileExporter.exportTrustProfile(to: tempURL)
            let profileData = try Data(contentsOf: tempURL)
            logger.info("Profile server: serving trust profile (\(profileData.count) bytes)")
            profileServedHandler?()
            profileServedHandler = nil  // fire once per server session
            return httpResponse(
                status: "200 OK",
                contentType: "application/x-apple-aspen-config",
                filename: "JoesProxy.mobileconfig",
                body: profileData
            )
        } catch {
            logger.error("Profile server: profile generation failed — \(error.localizedDescription)")
            return errorResponse(message: "Certificate not ready: \(error.localizedDescription)")
        }
    }

    private func certResponse() -> Data {
        guard let identity = certificateAuthority.currentRootCertificate() else {
            logger.warning("Profile server: certificate requested but unavailable")
            return errorResponse(message: "Certificate not available. Complete HTTPS setup first.")
        }
        logger.info("Profile server: serving root certificate (\(identity.certificateData.count) bytes)")
        return httpResponse(
            status: "200 OK",
            contentType: "application/x-x509-ca-cert",
            filename: "JoesProxy-Root-CA.cer",
            body: identity.certificateData
        )
    }

    private func landingPageResponse() -> Data {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>JoesProxy Certificate Setup</title>
        <style>
        body { font-family: -apple-system, sans-serif; max-width: 480px; margin: 40px auto; padding: 0 20px; }
        h1 { font-size: 22px; }
        a { display: block; margin: 16px 0; font-size: 18px; text-decoration: none; color: #007aff; }
        p { color: #555; font-size: 14px; }
        </style>
        </head>
        <body>
        <h1>JoesProxy Certificate Setup</h1>
        <p>Tap a link to install the JoesProxy root certificate on this device.</p>
        <a href="/profile.mobileconfig">&#8250; Install Trust Profile (.mobileconfig)</a>
        <a href="/cert">&#8250; Download Root Certificate (.cer)</a>
        <p style="margin-top:32px; font-size:12px; color:#999;">Install the trust profile first (recommended). Tap the link, follow the prompts in Settings, then enable trust in Certificate Trust Settings.</p>
        </body>
        </html>
        """
        return httpResponse(
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8)
        )
    }

    private func errorResponse(message: String) -> Data {
        httpResponse(
            status: "503 Service Unavailable",
            contentType: "text/plain; charset=utf-8",
            body: Data(message.utf8)
        )
    }

    /// - Parameter filename: When present, sent as `Content-Disposition: attachment;
    ///   filename="..."`. Safari's install-profile interception keys off `Content-Type` alone and
    ///   doesn't need this, but any client that falls back to extension-based type recognition —
    ///   a non-Safari browser saving to Files, or a generic download tool — needs an explicit,
    ///   correctly-suffixed filename to have any chance of the OS recognizing the saved file as a
    ///   `.mobileconfig`/`.cer` afterward.
    private func httpResponse(status: String, contentType: String, filename: String? = nil, body: Data) -> Data {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)"
        ]
        if let filename {
            headerLines.append("Content-Disposition: attachment; filename=\"\(filename)\"")
        }
        headerLines.append("Content-Length: \(body.count)")
        headerLines.append("Connection: close")
        headerLines.append("")
        headerLines.append("")
        var response = Data(headerLines.joined(separator: "\r\n").utf8)
        response.append(body)
        return response
    }
}
