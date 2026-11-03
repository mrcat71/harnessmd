import XCTest
@testable import HarnessKit

final class AnalyzerTests: XCTestCase {
    private func inventory(_ fixture: Fixture, files: [TrackedFile], extraSources: [Source] = []) -> Inventory {
        var inventory = Inventory(); inventory.sources = [fixture.source] + extraSources
        inventory.files = files.map { file in var copy = file; copy.blob = file.id; return copy }
        return inventory
    }

    func testSimilarity() {
        for (a, b, expected) in [("A small TEST.", "a small test", 1.0), ("one two three", "four five six", 0.0), ("", "", 1.0), ("", "text", 0.0)] {
            XCTAssertEqual(Analyzer.similarity(a, b), expected, accuracy: 0.001)
        }
    }

    func testOutOfSyncCopiesAndMissingPaths() throws {
        let fixture = try Fixture()
        let other = Source(root: fixture.root.appendingPathComponent("repos/other").path)
        let agents = fixture.file
        let claude = TrackedFile(sourceID: agents.sourceID, path: "CLAUDE.md", category: "instructions", tool: "claude")
        let copy = TrackedFile(sourceID: other.id, path: "AGENTS.md", category: "instructions", tool: "codex")
        let skillA = TrackedFile(sourceID: agents.sourceID, path: ".agents/skills/check", category: "skills", tool: "shared", isDirectory: true)
        let skillB = TrackedFile(sourceID: other.id, path: ".claude/skills/check", category: "skills", tool: "claude", isDirectory: true)
        let text = "Use small changes and run all tests before handing off. See `missing/check.sh`."
        let findings = Analyzer.analyze(inventory(fixture, files: [agents, claude, copy, skillA, skillB], extraSources: [other]), snapshots: [
            agents.id: .text(text), claude.id: .text("Something entirely unrelated about bright trees."), copy.id: .text(text),
            skillA.id: Snapshot(entries: ["SKILL.md": Data("a".utf8)]), skillB.id: Snapshot(entries: ["SKILL.md": Data("b".utf8)]),
        ])
        // Two kinds only: AGENTS.md vs CLAUDE.md and diverged skill copies are out of sync; the cross-repo copy is not reported.
        XCTAssertEqual(findings.map(\.kind).sorted(), ["stale", "stale", "sync", "sync"])
        XCTAssertFalse(findings.contains { $0.fileIDs.contains(copy.id) && $0.kind == "sync" })
        XCTAssertEqual(Set(findings.map(\.id)).count, findings.count)
        XCTAssertEqual(Set(findings.map(\.key)).count, findings.count)
    }

    func testFindingKeysFollowTheProblemNotTheNumbers() throws {
        let fixture = try Fixture()
        let agents = fixture.file
        let claude = TrackedFile(sourceID: agents.sourceID, path: "CLAUDE.md", category: "instructions", tool: "claude")
        func findings(_ agentsText: String, _ claudeText: String) -> [Finding] {
            Analyzer.analyze(inventory(fixture, files: [agents, claude]), snapshots: [agents.id: .text(agentsText), claude.id: .text(claudeText)])
        }
        let before = findings("Run tests. See `missing/a.sh`.", "Entirely different words about bright trees.")
        let after = findings("Run all tests. See `missing/a.sh` and `missing/b.sh`.", "Entirely different words about rivers.")
        func key(_ list: [Finding], _ kind: String) -> String? { list.first { $0.kind == kind }?.key }
        // The same pair still disagreeing keeps "It's fine"; a new missing path is a new problem.
        XCTAssertEqual(key(before, "sync"), key(after, "sync"))
        XCTAssertNotEqual(key(before, "stale"), key(after, "stale"))
    }

    func testMissingPathsCollapseIntoOneFindingPerFile() throws {
        let fixture = try Fixture()
        let findings = Analyzer.analyze(inventory(fixture, files: [fixture.file]), snapshots: [fixture.file.id: .text("See `missing/a.sh`, `missing/b.sh`, and `missing/a.sh` again.")])
        XCTAssertEqual(findings.map(\.title), ["2 referenced paths are missing"])
        XCTAssertEqual(findings.first?.detail, "AGENTS.md references missing/a.sh, missing/b.sh.")
    }

    func testImportsAndUnrelatedInstructionKindsAreNotDrift() throws {
        let fixture = try Fixture()
        let agents = fixture.file
        let claude = TrackedFile(sourceID: agents.sourceID, path: "CLAUDE.md", category: "instructions", tool: "claude")
        let desu = TrackedFile(sourceID: agents.sourceID, path: "DESU.md", category: "instructions", tool: "shared")
        let nested = TrackedFile(sourceID: agents.sourceID, path: "docs/CLAUDE.md", category: "instructions", tool: "claude")
        let body = "# Project\nRun swift test before handing off. Keep changes small and focused. Never commit secrets.\n"
        let imported = Analyzer.analyze(inventory(fixture, files: [agents, claude, desu, nested]), snapshots: [
            agents.id: .text(body), claude.id: .text("@AGENTS.md\n"), desu.id: .text("Personal notes about something else entirely."), nested.id: .text("Docs-only guidance with other words."),
        ])
        XCTAssertFalse(imported.contains { $0.kind == "sync" })
        let unrelated = Analyzer.analyze(inventory(fixture, files: [agents, claude]), snapshots: [agents.id: .text(body), claude.id: .text("Entirely different words about bright trees and rivers.")])
        XCTAssertEqual(unrelated.map(\.kind), ["sync"])
    }

    func testHostsAndSlugsAreNotMissingPaths() throws {
        let fixture = try Fixture()
        try fixture.write("charts/README.md", "charts")
        try fixture.write("playbooks/inventories/prod/hosts", "[all]")
        let text = """
        Push to `registry.example.com/ops/helm-charts/common-charts`, see `github.com/org/repo/blob/main/README.md`,
        import `go.uber.org/zap`, pull `bitnami/redis`, and fork `org/repo`.
        From playbooks, run with `inventories/prod/hosts` and check `inventories/prod/group_vars.yml`.
        Broken: `charts/old-values.yaml`, `./scripts/deploy`, and `docs/setup.md`.
        """
        let findings = Analyzer.analyze(inventory(fixture, files: [fixture.file]), snapshots: [fixture.file.id: .text(text)])
        XCTAssertEqual(findings.map(\.detail), ["AGENTS.md references inventories/prod/group_vars.yml, charts/old-values.yaml, ./scripts/deploy, docs/setup.md."])
    }

    func testStalePathsResolveRelativeToTheFile() throws {
        let fixture = try Fixture()
        try fixture.write("docs/guides/setup.md", "setup")
        let nested = TrackedFile(sourceID: fixture.source.id, path: "docs/AGENTS.md", category: "instructions", tool: "codex")
        let findings = Analyzer.analyze(inventory(fixture, files: [nested]), snapshots: [nested.id: .text("Read `guides/setup.md` and `docs/guides/setup.md`.")])
        XCTAssertTrue(findings.isEmpty, "\(findings)")
    }

    func testSyncedSkillCopiesAreNotReported() throws {
        let fixture = try Fixture()
        let other = Source(root: "/elsewhere/repo")
        let a = TrackedFile(sourceID: fixture.source.id, path: ".claude/skills/check", category: "skills", tool: "claude", isDirectory: true)
        let b = TrackedFile(sourceID: other.id, path: ".agents/skills/check", category: "skills", tool: "shared", isDirectory: true)
        let same = Snapshot(entries: ["SKILL.md": Data("# Check".utf8)])
        XCTAssertTrue(Analyzer.analyze(inventory(fixture, files: [a, b], extraSources: [other]), snapshots: [a.id: same, b.id: same]).isEmpty)
        // A per-tool rendering that adds one line is still the same skill.
        let body = (1...40).map { "Step \($0): inspect the change, run the focused checks, and report the evidence clearly." }.joined(separator: "\n")
        let rendered = Snapshot(entries: ["SKILL.md": Data((body + "\nInvoke with $check in Codex.").utf8)])
        XCTAssertTrue(Analyzer.analyze(inventory(fixture, files: [a, b], extraSources: [other]), snapshots: [a.id: Snapshot(entries: ["SKILL.md": Data(body.utf8)]), b.id: rendered]).isEmpty)
    }
}
