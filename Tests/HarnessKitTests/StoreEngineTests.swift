import XCTest
import GRDB
@testable import HarnessKit

@MainActor final class StoreEngineTests: XCTestCase {
    func testMigrationDeduplicationPersistenceAndTombstones() throws {
        let fixture = try Fixture(), store = try fixture.store()
        try store.save(fixture.source)
        try store.capture(fixture.file, snapshot: .text("first"), origin: "scan")
        try store.capture(fixture.file, snapshot: .text("first"), origin: "scan")
        XCTAssertEqual(try store.inventory().versions.count, 1)
        var second = fixture.file; second.id = "second"; second.path = "CLAUDE.md"
        try store.capture(second, snapshot: .text("first"), origin: "scan")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("store/blobs").path).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("store/manifests").path).count, 1)
        try store.capture(fixture.file, snapshot: nil, origin: "scan")
        let reopened = try fixture.store()
        XCTAssertEqual(try reopened.inventory().versions.count, 3)
        let first = try XCTUnwrap(reopened.inventory().versions.last?.blob)
        XCTAssertEqual(try reopened.snapshot(blob: first), .text("first"))
        XCTAssertNil(try reopened.inventory().files.first { $0.id == fixture.file.id }?.blob)
    }

    func testStoreKeepsPlainContentAndSharesUnchangedSkillFiles() throws {
        let fixture = try Fixture(), store = try fixture.store()
        try store.save(fixture.source)
        let skill = TrackedFile(sourceID: fixture.source.id, path: ".claude/skills/check", category: "skills", tool: "claude", isDirectory: true)
        try store.capture(skill, snapshot: Snapshot(entries: ["SKILL.md": Data("# Check".utf8), "reference.md": Data("unchanged reference".utf8)]), origin: "scan")
        try store.capture(skill, snapshot: Snapshot(entries: ["SKILL.md": Data("# Check v2".utf8), "reference.md": Data("unchanged reference".utf8)]), origin: "scan")
        let blobs = fixture.root.appendingPathComponent("store/blobs")
        let names = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        XCTAssertEqual(names.count, 3)
        // Contents are stored verbatim, so the store stays greppable.
        XCTAssertTrue(try names.map { try String(contentsOf: blobs.appendingPathComponent($0), encoding: .utf8) }.contains("unchanged reference"))
        let latest = try XCTUnwrap(store.inventory().files.first?.blob)
        XCTAssertEqual(try store.snapshot(blob: latest, entries: ["SKILL.md"]).entries, ["SKILL.md": Data("# Check v2".utf8)])
    }

    func testBlobIntegrityIsVerified() throws {
        let fixture = try Fixture(), store = try fixture.store()
        try store.save(fixture.source); try store.capture(fixture.file, snapshot: .text("first"), origin: "scan")
        let blob = try XCTUnwrap(store.inventory().files.first?.blob)
        try Data("corrupt".utf8).write(to: fixture.root.appendingPathComponent("store/blobs/" + digest(Data("first".utf8))))
        XCTAssertThrowsError(try store.snapshot(blob: blob)) { XCTAssertEqual($0 as? HarnessError, .missingBlob) }
        try Data("corrupt".utf8).write(to: fixture.root.appendingPathComponent("store/manifests/" + blob))
        XCTAssertThrowsError(try store.snapshot(blob: blob)) { XCTAssertEqual($0 as? HarnessError, .missingBlob) }
        XCTAssertThrowsError(try store.snapshot(blob: "../AGENTS.md"))
    }

    func testRescanRepairsCorruptContent() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let blob = try XCTUnwrap(inventory.files.first?.blob)
        try Data("corrupt".utf8).write(to: fixture.root.appendingPathComponent("store/blobs/" + digest(Data("original".utf8))))
        let report = try await engine.scan()
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
        let repaired = try await engine.snapshot(blob: blob)
        XCTAssertEqual(repaired.displayText, "original")
    }

    func testCorruptSnapshotDoesNotBreakFindingsOrUnrelatedAnalysis() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "first file"); try fixture.write("CLAUDE.md", "second file")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let agents = try XCTUnwrap(inventory.files.first { $0.path == "AGENTS.md" })
        let claude = try XCTUnwrap(inventory.files.first { $0.path == "CLAUDE.md" })
        try Data("corrupt".utf8).write(to: fixture.root.appendingPathComponent("store/manifests/" + agents.blob!))
        let report = try await engine.findings()
        XCTAssertEqual(report.warnings.count, 1)
        let request = try await engine.prepareAnalysis(fileIDs: [claude.id])
        XCTAssertEqual(request.inputs.map(\.fileID), [claude.id])
    }

    func testScanDeletionAndRestoreWithPreSnapshot() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine()
        _ = try await engine.scan()
        let initial = try await engine.inventory()
        let first = try XCTUnwrap(initial.versions.first)
        try fixture.write("AGENTS.md", "modified")
        _ = try await engine.scan()
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("AGENTS.md"))
        _ = try await engine.scan()
        let deleted = try await engine.inventory()
        XCTAssertNil(deleted.files.first?.blob)
        try await engine.restore(versionID: first.id)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "original")
        let restored = try await engine.inventory()
        XCTAssertEqual(restored.versions.count, 5)
        XCTAssertTrue(restored.versions.contains { $0.origin == "pre_restore" && $0.blob == nil })
    }

    func testRestoreOverUnstorableContentNeedsConsent() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let version = try await engine.inventory().versions[0]
        try fixture.write("AGENTS.md", "pasted by mistake: password = hunter2hunter2")
        do { try await engine.restore(versionID: version.id); XCTFail("Must ask before overwriting") }
        catch { guard case HarnessError.unstorableCurrent = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("hunter2"))
        try await engine.restore(versionID: version.id, overwriteUnstorableCurrent: true)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "original")
        let history = try await engine.versions(fileID: version.fileID)
        XCTAssertFalse(history.contains { $0.origin == "pre_restore" })
        XCTAssertTrue(history[0].note.contains("not stored"))
    }

    func testSensitiveChangeDoesNotEnterStoreOrCreateFalseDeletion() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "safe original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        try fixture.write("AGENTS.md", "api_key = not-a-real-synthetic-secret")
        let report = try await engine.scan()
        XCTAssertFalse(report.warnings.isEmpty)
        let inventory = try await engine.inventory()
        XCTAssertEqual(inventory.versions.count, 1)
        let snapshot = try await engine.snapshot(blob: inventory.files[0].blob!)
        XCTAssertEqual(snapshot.displayText, "safe original")
    }

    func testWatchedCaptureContinuesPastFailures() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "safe a"); try fixture.write("CLAUDE.md", "safe b")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        try fixture.write("AGENTS.md", "token = synthetic-not-real-secret")
        try fixture.write("CLAUDE.md", "safe b, edited")
        let warnings = try await engine.captureWatched(fileIDs: Set(inventory.files.map(\.id)))
        XCTAssertEqual(warnings.count, 1)
        let claude = try XCTUnwrap(inventory.files.first { $0.path == "CLAUDE.md" })
        let history = try await engine.versions(fileID: claude.id)
        XCTAssertEqual(history.count, 2)
    }

    func testDisabledAndRemovedRootsStopWatcherCapture() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "first")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        var source = inventory.sources[0]; source.enabled = false
        try await engine.save(source: source)
        try fixture.write("AGENTS.md", "second")
        _ = try await engine.captureWatched(fileIDs: [inventory.files[0].id])
        var after = try await engine.inventory()
        XCTAssertEqual(after.versions.count, 1)
        source.enabled = true; try await engine.save(source: source)
        try await engine.save(settings: AppSettings())
        _ = try await engine.captureWatched(fileIDs: [inventory.files[0].id])
        after = try await engine.inventory()
        XCTAssertEqual(after.versions.count, 1)
    }

    func testCorruptRestoreDoesNotTouchOriginal() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let version = try await engine.inventory().versions[0]
        try Data().write(to: fixture.root.appendingPathComponent("store/manifests/" + version.blob!))
        do { try await engine.restore(versionID: version.id); XCTFail("Must reject corrupt content") } catch {}
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "original")
    }

    func testPartialDiscoveryFailureKeepsHealthyRootsAndHistory() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine()
        var settings = try await engine.settings(); settings.roots.append(fixture.root.appendingPathComponent("missing").path)
        try await engine.save(settings: settings)
        let report = try await engine.scan()
        XCTAssertEqual(report.files, 1)
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testLinkedSkillsWarnOnlyWhenTheirTargetIsNotCollected() async throws {
        let fixture = try Fixture()
        let home = fixture.repo
        try fixture.write(".agent-skills/review/SKILL.md", "# Review")
        try fixture.link(".claude/skills/review/SKILL.md", to: home.appendingPathComponent(".agent-skills/review/SKILL.md"))
        try fixture.write("elsewhere/other/SKILL.md", "# Other")
        try fixture.link(".claude/skills/other/SKILL.md", to: home.appendingPathComponent("elsewhere/other/SKILL.md"))
        let engine = try Engine(directory: fixture.root.appendingPathComponent("store"))
        var settings = AppSettings(); settings.includeGlobals = true
        try await engine.save(settings: settings)
        let report = try await engine.scan(home: home)
        XCTAssertEqual(report.warnings.count, 1, "\(report.warnings)")
        XCTAssertTrue(report.warnings[0].contains("1 skill links"))
        let inventory = try await engine.inventory()
        XCTAssertEqual(inventory.files.filter(\.isDirectory).map(\.path), ["review"])
    }

    func testNarrowerPolicyStopsRecheckingWithoutFalseDeletion() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Main")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        // A unit recorded under an older, broader policy.
        let store = try fixture.store()
        let legacy = TrackedFile(sourceID: fixture.source.id, path: ".claude/worktrees/feature/AGENTS.md", category: "instructions", tool: "codex")
        try store.capture(legacy, snapshot: .text("# Old"), origin: "scan")
        let worktree = fixture.repo.appendingPathComponent(".claude/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(fixture.repo.path)/.git/worktrees/feature\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        _ = try await engine.scan()
        let history = try await engine.versions(fileID: legacy.id)
        // Only the original capture: no tombstone for a file outside the policy.
        XCTAssertEqual(history.map(\.origin), ["initial"])
    }

    func testInventoryBoundsRecentVersionsAndCountsHistory() throws {
        let fixture = try Fixture(), store = try fixture.store()
        try store.save(fixture.source)
        let total = Store.recentVersionLimit + 5
        for index in 0..<total { try store.capture(fixture.file, snapshot: .text("v\(index)"), origin: "scan") }
        let inventory = try store.inventory()
        XCTAssertEqual(inventory.versions.count, Store.recentVersionLimit)
        XCTAssertEqual(inventory.changes.count, Store.recentVersionLimit)
        XCTAssertEqual(inventory.versionCounts[fixture.file.id], total)
        // The first capture starts the timeline and is not a change.
        XCTAssertEqual(inventory.changesToday, total - 1)
        let history = try store.versions(fileID: fixture.file.id)
        XCTAssertEqual(history.count, total)
        XCTAssertEqual(history.last?.origin, "initial")
        XCTAssertEqual(try store.snapshot(blob: history[0].blob!), .text("v\(total - 1)"))
        XCTAssertEqual(try store.version(id: history[0].id)?.id, history[0].id)
    }

    func testFirstCaptureStartsTheTimelineWithoutCountingAsAChange() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        var inventory = try await engine.inventory()
        XCTAssertEqual(inventory.versions.map(\.origin), ["initial"])
        XCTAssertTrue(inventory.changes.isEmpty)
        XCTAssertEqual(inventory.changesToday, 0)
        try fixture.write("AGENTS.md", "edited")
        _ = try await engine.scan()
        inventory = try await engine.inventory()
        XCTAssertEqual(inventory.changes.map(\.origin), ["scan"])
        XCTAssertEqual(inventory.changesToday, 1)
    }

    func testLegacyPayloadStoreIsMigratedLosslessly() throws {
        let fixture = try Fixture()
        let directory = fixture.root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacySnapshot = try encoder.encode(Snapshot.text("legacy content")), legacyBlob = digest(legacySnapshot)
        try legacySnapshot.write(to: directory.appendingPathComponent("blobs/" + legacyBlob))
        var file = fixture.file; file.blob = legacyBlob
        let version = Version(fileID: file.id, blob: legacyBlob, origin: "scan", note: "Content captured")
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("store.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sources (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE files (id TEXT PRIMARY KEY, sourceID TEXT NOT NULL REFERENCES sources(id), payload BLOB NOT NULL);
                CREATE TABLE versions (id TEXT PRIMARY KEY, fileID TEXT NOT NULL REFERENCES files(id), capturedAt DOUBLE NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX versions_file ON versions(fileID, capturedAt);
                CREATE TABLE proposals (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE invocations (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE settings (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                """)
        }
        try migrator.migrate(queue)
        let invocation = AIInvocation(backend: "claude", model: "", fileIDs: [file.id], status: "running")
        // The request that produced the proposal below; proposals didn't record their files yet.
        var completed = AIInvocation(backend: "ollama", model: "gemma", fileIDs: [file.id], status: "completed")
        completed.date = Date().addingTimeInterval(-60)
        // v0.1 proposals predate the instructions field.
        let legacyEdit = ProposalEdit(fileID: file.id, baseBlob: legacyBlob, content: "kept")
        var legacyProposal = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Proposal(model: "claude/CLI default", rationale: "Keep it.", edits: [legacyEdit], note: "legacy"))) as? [String: Any])
        legacyProposal["instructions"] = nil; legacyProposal["fileIDs"] = nil
        legacyProposal["edits"] = [["fileID": file.id, "baseBlob": legacyBlob, "content": "kept"]]
        let proposalPayload = try JSONSerialization.data(withJSONObject: legacyProposal)
        let proposalID = try XCTUnwrap(legacyProposal["id"] as? String)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO proposals VALUES (?, ?)", arguments: [proposalID, proposalPayload])
            try db.execute(sql: "INSERT INTO sources VALUES (?, ?)", arguments: [fixture.source.id, JSONEncoder().encode(fixture.source)])
            try db.execute(sql: "INSERT INTO files VALUES (?, ?, ?)", arguments: [file.id, file.sourceID, JSONEncoder().encode(file)])
            try db.execute(sql: "INSERT INTO versions VALUES (?, ?, ?, ?)", arguments: [version.id, file.id, version.capturedAt.timeIntervalSince1970, JSONEncoder().encode(version)])
            try db.execute(sql: "INSERT INTO invocations VALUES (?, ?)", arguments: [invocation.id, JSONEncoder().encode(invocation)])
            try db.execute(sql: "INSERT INTO invocations VALUES (?, ?)", arguments: [completed.id, JSONEncoder().encode(completed)])
            try db.execute(sql: "INSERT INTO settings VALUES ('app', ?)", arguments: [Data(#"{"roots":["/legacy"]}"#.utf8)])
        }
        try queue.close()
        let store = try Store(directory: directory)
        let inventory = try store.inventory()
        XCTAssertEqual(inventory.sources.map(\.id), [fixture.source.id])
        XCTAssertEqual(inventory.files.first?.blob, legacyBlob)
        XCTAssertEqual(inventory.versions.map(\.id), [version.id])
        // v0.1 labeled a first capture as a scan; the migration marks it as the start of the timeline.
        XCTAssertEqual(inventory.versions.map(\.origin), ["initial"])
        XCTAssertEqual(inventory.proposals.map(\.instructions), [""])
        XCTAssertEqual(inventory.proposals.map(\.fileIDs), [[file.id]])
        // Earlier proposals count as analyses of their base content with their task.
        XCTAssertEqual(try store.analyzedTasks(of: [(file.id, legacyBlob)]), [file.id: [AIService.taskKey("")]])
        XCTAssertEqual(inventory.invocations.map(\.status), ["interrupted", "completed"])
        XCTAssertEqual(try store.snapshot(blob: legacyBlob).displayText, "legacy content")
        XCTAssertEqual(try store.settings().roots, ["/legacy"])
        // The first scan after upgrading re-encodes unchanged content without recording a change.
        try store.capture(file, snapshot: .text("legacy content"), origin: "scan")
        XCTAssertEqual(try store.versions(fileID: file.id).count, 1)
        XCTAssertEqual(try store.inventory().files.first?.blob, try Snapshot.text("legacy content").identity())
        try store.capture(file, snapshot: .text("edited after upgrade"), origin: "scan")
        XCTAssertEqual(try store.versions(fileID: file.id).map(\.origin), ["scan", "initial"])
    }
}
