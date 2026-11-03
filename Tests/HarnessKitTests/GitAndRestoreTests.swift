import XCTest
@testable import HarnessKit

@MainActor final class GitAndRestoreTests: XCTestCase {
    /// A minimal SHA-1 index in the on-disk format, so parsing is tested without running Git.
    private func indexData(version: UInt32, paths: [String]) -> Data {
        func word(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
        var bytes = Array("DIRC".utf8) + word(version) + word(UInt32(paths.count))
        var previous: [UInt8] = []
        for path in paths {
            let start = bytes.count, name = Array(path.utf8)
            bytes += [UInt8](repeating: 0, count: 40) + [UInt8](repeating: 0xab, count: 20)
            bytes += [UInt8(name.count >> 8 & 0x0f), UInt8(name.count & 0xff)]
            if version == 4 {
                let common = zip(previous, name).prefix { $0 == $1 }.count
                bytes += [UInt8(previous.count - common)] + name.dropFirst(common) + [0]
            } else {
                bytes += name + [0]
                while (bytes.count - start) % 8 != 0 { bytes.append(0) }
            }
            previous = name
        }
        return Data(bytes + [UInt8](repeating: 0, count: 20))
    }

    func testIndexVersionsTwoAndFourParse() throws {
        let paths = [".claude/skills/review/SKILL.md", ".claude/skills/review/notes.md", "AGENTS.md", "docs/CLAUDE.md"]
        for version: UInt32 in [2, 4] {
            let index = try XCTUnwrap(GitIndex.parse(indexData(version: version, paths: paths)), "version \(version)")
            XCTAssertEqual(index.paths, Set(paths), "version \(version)")
        }
        XCTAssertNil(GitIndex.parse(Data("not an index".utf8)))
    }

    func testRealGitIndexMarksAddedFilesOnly() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is not installed") }
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "# Added")
        try fixture.write("CLAUDE.md", "# Never added")
        try git(["init", "-q"], in: fixture.repo)
        try git(["add", "AGENTS.md"], in: fixture.repo)
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let agents = try XCTUnwrap(inventory.files.first { $0.path == "AGENTS.md" })
        let claude = try XCTUnwrap(inventory.files.first { $0.path == "CLAUDE.md" })
        XCTAssertEqual(inventory.gitTracked[agents.id], true)
        XCTAssertEqual(inventory.gitTracked[claude.id], false)
        // Adding the file later shows up on the next read; the cache follows the index file.
        try git(["add", "CLAUDE.md"], in: fixture.repo)
        let updated = try await engine.inventory()
        XCTAssertEqual(updated.gitTracked[claude.id], true)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = directory
        // A user's global gitignore may list AGENTS.md; the fixture needs Git's defaults.
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("git \(arguments.joined(separator: " ")) failed") }
    }

    func testCustomPatternsCollectExtraInstructionFiles() throws {
        let fixture = try Fixture()
        for path in ["GEMINI.md", "docs/gemini.md", ".kilocode/rules/style.md", ".kilocode/rules/deep/nested.md", "prompts/a/b/review.prompt.md", "notes.md"] {
            try fixture.write(path, "content")
        }
        let scanner = Scanner(customPatterns: ["GEMINI.md", ".kilocode/rules/*.md", "**/*.prompt.md"])
        let paths = Set(try scanner.files(in: fixture.source).map(\.path))
        XCTAssertEqual(paths, ["GEMINI.md", "docs/gemini.md", ".kilocode/rules/style.md", "prompts/a/b/review.prompt.md"])
        XCTAssertTrue(try scanner.files(in: fixture.source).allSatisfy { $0.category == "instructions" })
        for invalid in ["", "/etc/hosts", "../escape.md", "a/../b.md"] { XCTAssertNil(Scanner.globRegex(invalid), invalid) }
    }

    func testPointInTimeRestorePlansAndRestoresEachFile() async throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "agents v1"); try fixture.write("CLAUDE.md", "claude v1")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let before = try await engine.inventory()
        let agents = try XCTUnwrap(before.files.first { $0.path == "AGENTS.md" })
        let claude = try XCTUnwrap(before.files.first { $0.path == "CLAUDE.md" })
        try await Task.sleep(for: .milliseconds(30))
        let checkpoint = Date()
        try await Task.sleep(for: .milliseconds(30))
        try fixture.write("AGENTS.md", "agents v2")
        try fixture.write("DESU.md", "added later")
        _ = try await engine.scan()
        let after = try await engine.inventory()
        let desu = try XCTUnwrap(after.files.first { $0.path == "DESU.md" })

        let plans = try await engine.planRestore(fileIDs: [agents.id, claude.id, desu.id], asOf: checkpoint)
        let actions = Dictionary(uniqueKeysWithValues: plans.map { ($0.file.path, $0.action) })
        XCTAssertEqual(actions, ["AGENTS.md": .restore, "CLAUDE.md": .unchanged, "DESU.md": .untracked])
        let report = await engine.restore(plans)
        XCTAssertEqual(report.restored, ["project/AGENTS.md"])
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "agents v1")
        // Nothing is deleted: the file that didn't exist then is left alone.
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("DESU.md"), encoding: .utf8), "added later")
        let history = try await engine.versions(fileID: agents.id)
        XCTAssertEqual(history.prefix(2).map(\.origin), ["restore", "pre_restore"])
    }

    func testBatchRestoreReportsFilesItCannotSnapshot() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let file = try XCTUnwrap(inventory.files.first)
        try await Task.sleep(for: .milliseconds(30))
        let checkpoint = Date()
        try fixture.write("AGENTS.md", "pasted by mistake: password = hunter2hunter2")
        let plans = try await engine.planRestore(fileIDs: [file.id], asOf: checkpoint)
        XCTAssertEqual(plans.map(\.action), [.restore])
        let report = await engine.restore(plans)
        XCTAssertTrue(report.restored.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("hunter2"))
    }
}
