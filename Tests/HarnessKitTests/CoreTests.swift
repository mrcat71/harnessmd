import XCTest
import Darwin
@testable import HarnessKit

final class CoreTests: XCTestCase {
    func testDigestAndSnapshotIdentityAreDeterministic() throws {
        XCTAssertEqual(digest(Data("hello".utf8)), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try Snapshot(entries: ["b": Data(), "a": Data()]).identity(), try Snapshot(entries: ["a": Data(), "b": Data()]).identity())
        XCTAssertNotEqual(try Snapshot.text("a").identity(), try Snapshot(entries: ["": Data("a".utf8)], executablePaths: [""]).identity())
    }

    func testOpenFileLimitIsRaisedButNeverLowered() {
        var original = rlimit(); getrlimit(RLIMIT_NOFILE, &original)
        defer { var restore = original; setrlimit(RLIMIT_NOFILE, &restore) }
        var lowered = original; lowered.rlim_cur = 256; setrlimit(RLIMIT_NOFILE, &lowered)
        XCTAssertEqual(raiseOpenFileLimit(to: 1024), 1024)
        var now = rlimit(); getrlimit(RLIMIT_NOFILE, &now)
        XCTAssertEqual(now.rlim_cur, 1024)
        XCTAssertEqual(raiseOpenFileLimit(to: 512), 1024)
        XCTAssertEqual(FileWatcher.defaultBudget(), 768)
    }

    func testItemsSharingAFileFormOneGroup() {
        // A diff for A, a check for A, a check spanning A and C, and an unrelated check for B.
        XCTAssertEqual(connectedGroups([["A"], ["A"], ["B"], ["A", "C"], ["C"]]), [[0, 1, 3, 4], [2]])
        XCTAssertEqual(connectedGroups([["B"], ["A"], ["B", "A"]]), [[0, 1, 2]])
        XCTAssertEqual(connectedGroups([]), [])
    }

    func testReviewMovesToTheNextRowAfterADecision() {
        let rows = [["d1"], ["c2", "d2"], ["c3"], ["d4"]]
        // Deciding row 0 removes it: row 1 (now first) is next.
        XCTAssertEqual(rowAfterDecision(before: rows, selected: [0], after: [["c2", "d2"], ["c3"], ["d4"]]), 0)
        // Deciding one item of row 1 keeps the row while its check remains.
        XCTAssertEqual(rowAfterDecision(before: rows, selected: [1], after: [["d1"], ["c2"], ["c3"], ["d4"]]), 1)
        // The last row goes back to the one before it.
        XCTAssertEqual(rowAfterDecision(before: rows, selected: [3], after: [["d1"], ["c2", "d2"], ["c3"]]), 2)
        // Several rows: the first row after the selection.
        XCTAssertEqual(rowAfterDecision(before: rows, selected: [0, 1], after: [["c3"], ["d4"]]), 0)
        XCTAssertNil(rowAfterDecision(before: rows, selected: [0, 1, 2, 3], after: []))
    }

    func testSettingsWithMissingKeysKeepDefaults() throws {
        let older = Data(#"{"roots":["/tmp/repos"],"includeGlobals":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: older)
        XCTAssertEqual(settings.roots, ["/tmp/repos"])
        XCTAssertTrue(settings.includeGlobals)
        XCTAssertEqual(settings.timeout, 120)
        XCTAssertEqual(settings.backend, "claude")
        XCTAssertEqual(settings.effort, "")
        XCTAssertFalse(settings.thoroughAnalysis)
        XCTAssertEqual(settings.ollamaURL, "http://127.0.0.1:11434")
        XCTAssertTrue(settings.backendChoices.isEmpty)
    }
}
