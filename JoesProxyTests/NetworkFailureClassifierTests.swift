import XCTest
@testable import JoesProxy

final class NetworkFailureClassifierTests: XCTestCase {
    func testURLErrorDNSMapsToDNSBucket() {
        let error = URLError(.cannotFindHost)
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .dnsFailure)
        XCTAssertTrue(presentation.userFacingMessage.localizedCaseInsensitiveContains("hostname"))
    }

    func testURLErrorTimeoutMapsToTimeoutBucket() {
        let error = URLError(.timedOut)
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .timeout)
        XCTAssertTrue(presentation.userFacingMessage.localizedCaseInsensitiveContains("time"))
    }

    func testURLErrorOfflineMapsToProbableNoConnectivityBucket() {
        let error = URLError(.notConnectedToInternet)
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .probableNoConnectivity)
    }

    func testPOSIXConnectionRefusedMapsToRefusedBucket() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 61)
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .refusedConnection)
    }

    func testNIOConnectionErrorDescriptionMapsToRefusedConnection() {
        let description = "The operation couldn't be completed. (NIOPosix.NIOConnectionError error 1.)"
        let presentation = NetworkFailureClassifier.presentation(forMessage: description)

        XCTAssertEqual(presentation.bucket, .refusedConnection)
        XCTAssertFalse(presentation.userFacingMessage.contains("NIOPosix"))
    }

    func testAddressAlreadyInUseMapsToLocalProxyStart() {
        let presentation = NetworkFailureClassifier.presentation(
            forMessage: "bind failed: Address already in use"
        )

        XCTAssertEqual(presentation.bucket, .localProxyStart)
        XCTAssertTrue(presentation.userFacingMessage.localizedCaseInsensitiveContains("port"))
    }

    func testHTTPUpstreamIncompleteResponseBucket() {
        let error = HTTPUpstreamConnectorError.incompleteResponse
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .incompleteResponse)
    }

    func testBookmarkExecutionTimedOutUsesTimeoutBucket() {
        let error = BookmarkExecutionError.timedOut
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .timeout)
    }

    func testCertificateAuthorityErrorMapsToCertificateSetup() {
        let error = CertificateAuthorityError.identityUnavailable
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .certificateSetup)
    }

    func testProxyInvalidPortMapsToLocalProxyStart() {
        let error = ProxyError.invalidPort
        let presentation = NetworkFailureClassifier.presentation(for: error)

        XCTAssertEqual(presentation.bucket, .localProxyStart)
    }

    func testFileExportPermissionErrorMapsToFileAccessBucket() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSLocalizedDescriptionKey: "You don’t have permission to save the file."
        ])
        let presentation = NetworkFailureClassifier.presentation(for: error, surface: .fileExport)

        XCTAssertEqual(presentation.bucket, .fileAccess)
        XCTAssertTrue(presentation.userFacingMessage.localizedCaseInsensitiveContains("permission"))
    }

    func testProfileServerBindFailureMapsToLocalProxyStart() {
        let error = ProfileHostingServer.ServerError.bindFailed("Address already in use")
        let presentation = NetworkFailureClassifier.presentation(for: error, surface: .profileServer)

        XCTAssertEqual(presentation.bucket, .localProxyStart)
        XCTAssertTrue(presentation.userFacingMessage.localizedCaseInsensitiveContains("8765"))
    }

    func testSessionFailureStoresBucketFromRecorderPath() async {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let request = CapturedRequest(
            method: "GET",
            scheme: .http,
            inspectionKind: .plain,
            host: "example.com",
            port: 80,
            path: "/",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let sessionID = await recorder.beginSession(request: request)
        await recorder.failSession(id: sessionID, error: URLError(.timedOut))
        await recorder.waitForPendingStoreFlush()

        let sessions = await MainActor.run { store.sessions }
        XCTAssertEqual(sessions.first?.failure?.bucket, NetworkFailureBucket.timeout.rawValue)
        XCTAssertTrue(sessions.first?.failure?.message.localizedCaseInsensitiveContains("time") ?? false)
    }
}
