import XCTest
@testable import HarnessKit

final class ScannerTests: XCTestCase {
    func testRepositoryAndNestedInstructionDiscovery() throws {
        let fixture = try Fixture()
        for path in ["AGENTS.md", "CLAUDE.local.md", "docs/DESU.md", "nested/AGENTS.override.md", ".github/copilot-instructions.md", ".codex/config.toml", ".codex/rules/safe.rules", ".claude/commands/review.md", ".opencode/agents/reviewer.md", "opencode.jsonc"] { try fixture.write(path, "content") }
        for path in ["node_modules/pkg/AGENTS.md", ".git/CLAUDE.md", "normal.txt", "auth.json", "vendor/CLAUDE.md"] { try fixture.write(path, "ignored") }
        let scanner = Scanner()
        let sources = try scanner.discover(roots: [fixture.root.appendingPathComponent("repos").path], globals: false).sources
        XCTAssertEqual(sources.count, 1)
        let files = try scanner.files(in: sources[0])
        XCTAssertEqual(files.count, 10)
        XCTAssertEqual(Set(files.map(\.category)), ["instructions", "config", "prompts", "agents"])
        // Codex exec policies are configuration, never AI input.
        XCTAssertEqual(files.first { $0.path == ".codex/rules/safe.rules" }?.category, "config")
    }

    func testWholeSkillDirectoryIsOneTrackedUnit() throws {
        let fixture = try Fixture()
        for path in [".claude/skills/review/SKILL.md", ".claude/skills/review/scripts/check.sh", ".claude/skills/review/references/AGENTS.md", ".agents/skills/local/SKILL.md"] { try fixture.write(path, "content") }
        let files = try Scanner().files(in: fixture.source)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy(\.isDirectory))
        let skill = try XCTUnwrap(files.first { $0.tool == "claude" })
        let snapshot = try XCTUnwrap(SafeFiles.capture(root: fixture.repo.path, file: skill))
        XCTAssertEqual(snapshot.entries.count, 3)
    }

    func testGlobalMapsAndDenylist() throws {
        let fixture = try Fixture()
        let home = fixture.repo
        for path in [".claude/CLAUDE.md", ".claude/settings.json", ".claude/skills/check/SKILL.md", ".codex/AGENTS.md", ".codex/memories/note.md", ".codex/agents/test.toml", ".agents/skills/review/SKILL.md", ".config/opencode/AGENTS.md", ".config/opencode/commands/go.md", ".config/opencode/opencode.jsonc", ".codex/auth.json", ".claude.json"] { try fixture.write(path, "content") }
        let sources = try Scanner().discover(roots: [], globals: true, home: home).sources
        XCTAssertEqual(sources.count, 4)
        let files = try sources.flatMap { try Scanner().files(in: $0) }
        XCTAssertEqual(files.count, 10)
        XCTAssertFalse(files.contains { $0.path.contains("auth.json") })
    }

    func testGlobalCollectionSkipsCachesPluginsAndNestedMemories() throws {
        let fixture = try Fixture()
        for path in [".claude/plugins/marketplaces/vendor/CLAUDE.md", ".claude/plugins/cache/vendor/1.0/skills/x/SKILL.md", ".claude/projects/p/CLAUDE.md",
                     ".codex/.tmp/plugins/AGENTS.md", ".codex/worktrees/w/repo/AGENTS.md", ".codex/sessions/s.md", ".codex/memories/rollout_summaries/a.md",
                     ".codex/memories/MEMORY.md", ".codex/rules/default.rules", ".codex/agents/reviewer.toml"] { try fixture.write(path, "content") }
        let sources = try Scanner().discover(roots: [], globals: true, home: fixture.repo).sources
        let files = try sources.flatMap { try Scanner().files(in: $0) }
        XCTAssertEqual(Set(files.map(\.path)), ["memories/MEMORY.md", "rules/default.rules", "agents/reviewer.toml"])
        XCTAssertEqual(Set(files.map(\.category)), ["memories", "config"])
        XCTAssertFalse(files.contains { $0.allowsAI })
    }

    func testSymlinkedSkillsAreReportedAndAgentSkillsAreCollected() throws {
        let fixture = try Fixture()
        let home = fixture.repo
        try fixture.write(".agent-skills/review/SKILL.md", "# Review")
        try fixture.link(".claude/skills/review/SKILL.md", to: home.appendingPathComponent(".agent-skills/review/SKILL.md"))
        let sources = try Scanner().discover(roots: [], globals: true, home: home).sources
        let claude = try XCTUnwrap(sources.first { $0.kind == "claude" })
        let shared = try XCTUnwrap(sources.first { $0.kind == "agent-skills" })
        let listing = try Scanner().listing(of: claude)
        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertEqual(listing.linkedSkills, [shared.root + "/review"])
        XCTAssertEqual(try Scanner().files(in: shared).map(\.path), ["review"])
    }

    func testUnreadableDirectoryIsSkippedWithAWarning() throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "# Project")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("repos/healthy/.git"), withIntermediateDirectories: true)
        let locked = fixture.repo.appendingPathComponent("docker-data")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o700) }
        let discovery = try Scanner().discover(roots: [fixture.root.appendingPathComponent("repos").path], globals: false)
        XCTAssertEqual(discovery.sources.count, 2)
        XCTAssertEqual(discovery.warnings.count, 1)
        let listing = try Scanner().listing(of: fixture.source)
        XCTAssertEqual(listing.files.map(\.path), ["AGENTS.md"])
        XCTAssertEqual(listing.warnings.count, 1)
    }

    func testNestedWorktreesBelongOnlyToThemselves() throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "# Main")
        let worktree = fixture.repo.appendingPathComponent(".claude/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(fixture.repo.path)/.git/worktrees/feature\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        try Data("# Main".utf8).write(to: worktree.appendingPathComponent("AGENTS.md"))
        XCTAssertEqual(try Scanner().discover(roots: [fixture.root.appendingPathComponent("repos").path], globals: false).sources.count, 2)
        XCTAssertEqual(try Scanner().files(in: fixture.source).map(\.path), ["AGENTS.md"])
        let nested = TrackedFile(sourceID: fixture.source.id, path: ".claude/worktrees/feature/AGENTS.md", category: "instructions", tool: "codex")
        XCTAssertFalse(Scanner().stillCollected(nested, in: fixture.source))
        XCTAssertTrue(Scanner().stillCollected(fixture.file, in: fixture.source))
    }

    func testWorktreesKeepDistinctPathsButShareCanonicalIdentity() throws {
        let fixture = try Fixture()
        let worktree = fixture.root.appendingPathComponent("repos/worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(fixture.repo.path)/.git/worktrees/feature\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        let sources = try Scanner().discover(roots: [fixture.root.appendingPathComponent("repos").path], globals: false).sources
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.first { $0.isWorktree }?.repositoryRoot, fixture.repo.path)
        XCTAssertNotEqual(sources[0].id, sources[1].id)
    }

    func testSymlinksAreNotDiscovered() throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "content")
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent("CLAUDE.md"), withDestinationURL: fixture.repo.appendingPathComponent("AGENTS.md"))
        XCTAssertEqual(try Scanner().files(in: fixture.source).map(\.path), ["AGENTS.md"])
    }

    func testMissingRootFailsInsteadOfSilentlyEmpty() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(try Scanner().discover(roots: [fixture.root.appendingPathComponent("missing").path], globals: false))
    }
}
