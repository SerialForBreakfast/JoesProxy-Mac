import XCTest
@testable import JoesProxy

@MainActor
final class MCPHTTPSRecoveryJournalTests: XCTestCase {
    private func receipt(owner: String = UUID().uuidString) -> MCPHTTPSRecoveryJournal.Receipt {
        .init(id: UUID(), owner: owner, host: "media.example.test", mode: "tunnel",
              before: .init(), after: .init(bypassDomains: ["media.example.test"]), createdAt: Date())
    }

    private func scratchURL() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/TransportDiagnostics/RecoveryTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.json")
    }

    func testRestartPreservesIntentWithoutExecutingAndRejectsOtherOwner() throws {
        let url = try scratchURL()
        let original = receipt()
        try MCPHTTPSRecoveryJournal(url: url).save(original)
        let restarted = MCPHTTPSRecoveryJournal(url: url)
        let saved = try XCTUnwrap(restarted.receipt(id: original.id, owner: original.owner))
        XCTAssertEqual(saved.projection(current: saved.before)["state"] as? String, "not_applied")
        XCTAssertEqual(saved.projection(current: saved.after)["state"] as? String, "applied")
        XCTAssertEqual(saved.projection(current: .init(bypassDomains: ["other.example.test"]))["state"] as? String, "conflict")
        XCTAssertThrowsError(try restarted.receipt(id: original.id, owner: UUID().uuidString))
        var restoring = saved
        restoring.phase = .restorePrepared
        try restarted.save(restoring)
        let restored = try XCTUnwrap(MCPHTTPSRecoveryJournal(url: url).receipt(id: original.id, owner: original.owner))
        XCTAssertEqual(restored.projection(current: saved.before)["state"] as? String, "restored")
        XCTAssertEqual(restored.projection(current: saved.after)["state"] as? String, "restore_not_applied")
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: restored.projection(current: saved.before)).count, 4096)
    }

    func testBoundDoesNotEvictOutstandingRecoveryAndRetiresCompletedOnly() throws {
        let url = try scratchURL()
        let journal = MCPHTTPSRecoveryJournal(url: url)
        var first = receipt()
        try journal.save(first)
        for _ in 1..<MCPHTTPSRecoveryJournal.limit { try journal.save(receipt()) }
        XCTAssertThrowsError(try journal.save(receipt()))
        XCTAssertNotNil(try journal.receipt(id: first.id, owner: first.owner))
        first.phase = .restored
        try journal.save(first)
        try journal.save(receipt())
        XCTAssertThrowsError(try journal.receipt(id: first.id, owner: first.owner))
        XCTAssertThrowsError(try MCPHTTPSRecoveryJournal(url: url).receipt(id: first.id, owner: first.owner))
    }

    func testHistoryIsOwnerAndHostScopedAndBounded() throws {
        let journal = MCPHTTPSRecoveryJournal()
        let owner = UUID().uuidString
        let longHost = String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 63)
            + "." + String(repeating: "c", count: 63) + "." + String(repeating: "d", count: 56) + ".test"
        for _ in 0..<MCPHTTPSRecoveryJournal.limit {
            try journal.save(.init(id: UUID(), owner: owner, host: longHost, mode: "tunnel",
                before: .init(), after: .init(bypassDomains: [longHost]), createdAt: Date()))
        }
        let history = journal.history(host: longHost, owner: owner, current: .init())
        XCTAssertEqual(history["retainedCount"] as? Int, 32)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: history).count, 64 * 1024)
        XCTAssertEqual(journal.history(host: longHost, owner: "other", current: .init())["retainedCount"] as? Int, 0)
        XCTAssertEqual(journal.history(host: "other.example.test", owner: owner, current: .init())["retainedCount"] as? Int, 0)
    }

    func testUnreadableAndUnwritableJournalFailClosed() throws {
        let url = try scratchURL()
        try Data("not json".utf8).write(to: url)
        let journal = MCPHTTPSRecoveryJournal(url: url)
        XCTAssertThrowsError(try journal.save(receipt()))
        XCTAssertThrowsError(try journal.receipt(id: UUID(), owner: UUID().uuidString))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
        let impossible = MCPHTTPSRecoveryJournal(url: url.appendingPathComponent("child.json"))
        XCTAssertThrowsError(try impossible.save(receipt()))
    }
}
