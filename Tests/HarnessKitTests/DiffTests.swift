import XCTest
@testable import HarnessKit

final class DiffTests: XCTestCase {
    private let twenty = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"

    func testHunksKeepThreeLinesOfContextAndMergeNearbyChanges() {
        let after = twenty.replacingOccurrences(of: "line 5\n", with: "line five\n").replacingOccurrences(of: "line 7\n", with: "line seven\n")
            .replacingOccurrences(of: "line 18\n", with: "line eighteen\n")
        let hunks = TextDiff.hunks(before: twenty, after: after)
        XCTAssertEqual(hunks.map(\.header), ["@@ -2,9 +2,9 @@", "@@ -15,6 +15,6 @@"])
        XCTAssertEqual(hunks[0].lines.first, TextDiff.Line(kind: .context, old: 2, new: 2, text: "line 2"))
        XCTAssertEqual(hunks[0].lines.filter { $0.kind == .removed }.map(\.text), ["line 5", "line 7"])
        XCTAssertEqual(hunks[1].lines.last?.new, 20)
        XCTAssertTrue(TextDiff.hunks(before: twenty, after: twenty).isEmpty)
        // Inserting at the top of an empty side starts it at line 0, as Git does.
        XCTAssertEqual(TextDiff.hunks(before: "", after: "new\n").map(\.header), ["@@ -0,0 +1 @@"])
    }

    func testModifiedLinesMarkTheWordsThatChanged() throws {
        let hunks = TextDiff.hunks(before: "Run tests before handing off work.\n", after: "Run all tests before handing off work.\n")
        let removed = try XCTUnwrap(hunks.first?.lines.first { $0.kind == .removed })
        let added = try XCTUnwrap(hunks.first?.lines.first { $0.kind == .added })
        XCTAssertEqual(added.spans.filter(\.changed).map(\.text).joined().trimmingCharacters(in: .whitespaces), "all")
        XCTAssertEqual(added.spans.map(\.text).joined(), added.text)
        XCTAssertFalse(removed.spans.contains(where: \.changed))
        // Lines with little in common read as replaced, without word marks.
        let rewritten = TextDiff.hunks(before: "Deploy on Fridays.\n", after: "Never ship without review.\n")
        XCTAssertTrue(rewritten[0].lines.allSatisfy(\.spans.isEmpty))
    }

    func testPatchesApplyWithGit() throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: git.path), "git is not installed")
        let cases: [(String, String)] = [
            (twenty, twenty.replacingOccurrences(of: "line 10\n", with: "line ten\nline ten and a half\n")),
            ("first\nsecond", "first\nsecond\n"),
            ("first\nsecond\n", "first\nsecond"),
            ("drop me\nkeep\n", "keep\n"),
            ("keep\n", "keep\nadded at the end\n"),
            ("crlf line\r\nnext\r\n", "crlf line\r\nchanged\r\n"),
        ]
        for (before, after) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harnessmd-patch-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try Data(before.utf8).write(to: directory.appendingPathComponent("docs/AGENTS.md"))
            try Data(TextDiff.patch(before: before, after: after, path: "docs/AGENTS.md").utf8).write(to: directory.appendingPathComponent("change.patch"))
            let process = Process()
            process.executableURL = git; process.arguments = ["apply", "change.patch"]; process.currentDirectoryURL = directory
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git apply refused the patch for \(before.debugDescription)")
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("docs/AGENTS.md"), encoding: .utf8), after)
        }
        XCTAssertEqual(TextDiff.patch(before: "same", after: "same", path: "AGENTS.md"), "")
    }

    func testChangesArePlacedOnlyWhereTheyMatchOnce() {
        let text = "# Rules\n## Tests\nRun tests.\nRun tests.\n## Deploy\nShip on green.  \nTell the team.\n"
        func change(_ find: String, _ replace: String, _ why: String = "why") -> TextPatch.Change { TextPatch.Change(find: find, replace: replace, why: why) }
        let result = TextPatch.apply([
            change("## Deploy\nShip on green.\n", "## Deploy\nShip when CI is green.\n", "Name the signal."),
            change("Run tests.", "Run all tests.", "Repeated text is ambiguous."),
            change("Tell the team.\n", "", "Drop the vague rule."),
            change("", "## Owners\nAsk platform.\n", "Add owners."),
        ], to: text)
        XCTAssertEqual(result.text, "# Rules\n## Tests\nRun tests.\nRun tests.\n## Deploy\nShip when CI is green.\n## Owners\nAsk platform.\n")
        // Notes point at the first changed line: the shared heading is skipped.
        XCTAssertEqual(result.notes.map(\.line), [6, 7, 7])
        XCTAssertEqual(result.unplaced.map(\.reason), ["its text appears more than once"])
        let missing = TextPatch.apply([change("Deploy daily.", "Deploy weekly.")], to: text)
        XCTAssertEqual(missing.text, text)
        XCTAssertEqual(missing.unplaced.map(\.reason), ["its text is not in the file"])
        let overlapping = TextPatch.apply([change("## Tests\nRun tests.\nRun tests.", "## Tests"), change("Run tests.\nRun tests.\n## Deploy", "## Deploy")], to: text)
        XCTAssertEqual(overlapping.unplaced.map(\.reason), ["it overlaps another change"])
        // Appending to a file without a final newline starts a new line.
        XCTAssertEqual(TextPatch.apply([change("", "b\n")], to: "a").text, "a\nb\n")
    }

    func testCommonMisquotesStillPlace() {
        let text = "# Agents\n\nCommit with the ticket key.\n\nNever push to main.\n- Flags change routing. Dyn envs start from `fflags.yaml`.\n"
        // A quote that drops the blank line between paragraphs.
        let paragraphs = TextPatch.apply([TextPatch.Change(find: "Commit with the ticket key.\nNever push to main.", replace: "Commit with the ticket key. Never push to main.", why: "Join.")], to: text)
        XCTAssertEqual(paragraphs.text, "# Agents\n\nCommit with the ticket key. Never push to main.\n- Flags change routing. Dyn envs start from `fflags.yaml`.\n")
        // A sentence from the middle of a bullet, quoted with a marker of its own: the marker is dropped from both sides.
        let sentence = TextPatch.apply([TextPatch.Change(find: "- Dyn envs start from `fflags.yaml`.", replace: "- Dyn envs start from `deployment/envs/dyn/fflags.yaml`.", why: "Full path.")], to: text)
        XCTAssertEqual(sentence.text, "# Agents\n\nCommit with the ticket key.\n\nNever push to main.\n- Flags change routing. Dyn envs start from `deployment/envs/dyn/fflags.yaml`.\n")
        XCTAssertTrue(sentence.unplaced.isEmpty)
        // A renumbered item without its indentation: matched by text, and the file keeps its number and indent.
        let list = "1. Build.\n4. Inside a role, start\n   with defaults.\n5. Ship.\n"
        let renumbered = TextPatch.apply([TextPatch.Change(find: "5. Inside a role, start\nwith defaults.", replace: "5. Inside a role, start\nwith defaults and tasks.", why: "Name tasks.")], to: list)
        XCTAssertEqual(renumbered.text, "1. Build.\n4. Inside a role, start\n   with defaults and tasks.\n5. Ship.\n")
        // Line breaks written as a backslash and an n.
        let escaped = TextPatch.apply([TextPatch.Change(find: "4. Inside a role, start\\n   with defaults.", replace: "4. Inside a role, begin\\n   with defaults.", why: "Word.")], to: list)
        XCTAssertEqual(escaped.text, "1. Build.\n4. Inside a role, begin\n   with defaults.\n5. Ship.\n")
    }
}
