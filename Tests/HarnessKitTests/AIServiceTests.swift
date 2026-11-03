import XCTest
@testable import HarnessKit

private actor SpyRunner: ProcessRunning {
    var calls: [ProcessRequest] = []
    var configs: [Data] = []
    let output: String
    init(output: String) { self.output = output }
    func run(_ request: ProcessRequest) async throws -> String {
        calls.append(request)
        // The isolated workspace is deleted after the run, so keep the generated OpenCode config now.
        let config = request.directory.appendingPathComponent("config/opencode/opencode.json")
        if FileManager.default.fileExists(atPath: config.path) { configs.append(try Data(contentsOf: config)) }
        return output
    }
    func requests() -> [ProcessRequest] { calls }
    func openCodeConfigs() -> [Data] { configs }
}

@MainActor final class AIServiceTests: XCTestCase {
    /// A reply that replaces the first file's whole text with `content`.
    private func response(for request: AnalysisRequest, content: String = "# Improved\nRun tests.") throws -> String {
        let input = request.inputs[0]
        return try reply([["fileID": input.fileID, "find": input.content, "replace": content, "why": "Keep verification explicit."]])
    }

    private func reply(_ changes: [[String: String]], summary: String = "Keep verification explicit.") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["summary": summary, "changes": changes] as [String: Any]), as: UTF8.self)
    }

    func testPrivateConfigAndOutOfScopeFilesNeverEnterPayload() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Safe\nRun tests."); try fixture.write(".codex/config.toml", "model = 'example'")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: Set(inventory.files.map(\.id)))
        XCTAssertEqual(request.inputs.count, 1)
        XCTAssertFalse(request.prompt.contains("config.toml"))
        XCTAssertFalse(request.prompt.contains(fixture.root.path))
        var source = inventory.sources[0]; source.isPrivate = true; try await engine.save(source: source)
        do { _ = try await engine.prepareAnalysis(fileIDs: Set(inventory.files.map(\.id))); XCTFail("Private source leaked") } catch {}
        source.isPrivate = false; try await engine.save(source: source)
        try await engine.save(settings: AppSettings())
        do { _ = try await engine.prepareAnalysis(fileIDs: Set(inventory.files.map(\.id))); XCTFail("Removed source leaked") } catch {}
    }

    func testPreviewPrivacyIsRecheckedBeforeInvocation() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Safe\nRun tests.")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        var source = inventory.sources[0]; source.isPrivate = true; try await engine.save(source: source)
        let runner = SpyRunner(output: try response(for: request))
        do { try await engine.analyze(request, runner: runner); XCTFail("Should fail before sending") } catch {}
        let calls = await runner.requests()
        XCTAssertTrue(calls.isEmpty)
    }

    func testMockedCLIStoresProposalAndInvocationThenAppliesWithSafetySnapshot() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Original\nRun tests.")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        let runner = SpyRunner(output: try response(for: request))
        try await engine.analyze(request, runner: runner)
        let calls = await runner.requests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].arguments.contains("--safe-mode"))
        XCTAssertTrue(calls[0].arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(calls[0].arguments.contains("--tools"))
        XCTAssertEqual(calls[0].input, Data(request.prompt.utf8))
        XCTAssertFalse(calls[0].arguments.contains(request.prompt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls[0].directory.path))
        let pending = try await engine.inventory()
        XCTAssertEqual(pending.invocations[0].status, "completed")
        XCTAssertEqual(pending.proposals.count, 1)
        try await engine.accept(proposalID: pending.proposals[0].id)
        let after = try await engine.inventory()
        XCTAssertEqual(after.proposals[0].status, "accepted")
        XCTAssertTrue(after.versions.contains { $0.origin == "pre_apply" })
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "# Improved\nRun tests.")
    }

    func testChangedFileBlocksApplyWithoutOverwrite() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        try await engine.analyze(request, runner: SpyRunner(output: try response(for: request)))
        let proposal = try await engine.inventory().proposals[0]
        try fixture.write("AGENTS.md", "user modification after preview")
        do { try await engine.accept(proposalID: proposal.id); XCTFail("Must block stale apply") }
        catch { XCTAssertEqual(error as? HarnessError, .conflict) }
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "user modification after preview")
    }

    func testSkillAnalysisOnlyProposesSkillMarkdownAndPreservesBundle() async throws {
        let fixture = try Fixture()
        try fixture.write(".claude/skills/check/SKILL.md", "# Check\nReview carefully.")
        try fixture.write(".claude/skills/check/scripts/check.sh", "echo local-script-only")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        XCTAssertTrue(request.inputs[0].path.hasSuffix("/SKILL.md"))
        XCTAssertFalse(request.prompt.contains("local-script-only"))
        try await engine.analyze(request, runner: SpyRunner(output: try response(for: request)))
        let proposal = try await engine.inventory().proposals[0]
        try await engine.accept(proposalID: proposal.id)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent(".claude/skills/check/scripts/check.sh"), encoding: .utf8), "echo local-script-only")
    }

    func testRejectKeepsFileUnchanged() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        try await engine.analyze(request, runner: SpyRunner(output: try response(for: request)))
        let proposal = try await engine.inventory().proposals[0]
        try await engine.reject(proposalID: proposal.id)
        let rejected = try await engine.inventory()
        XCTAssertEqual(rejected.proposals[0].status, "rejected")
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "original")
    }

    func testParsingPlacesChangesReportsMissesAndRefusesUnsafeOutput() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Rules\nRun tests.\nShip it.\n"); try fixture.write("CLAUDE.md", "# Claude\nBe brief.\n")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let agents = try XCTUnwrap(inventory.files.first { $0.path == "AGENTS.md" })
        let single = try await engine.prepareAnalysis(fileIDs: [agents.id])
        // One file per request doesn't depend on the model copying its ID; the change can only land in that file.
        let specific = ["fileID": "not-an-id", "find": "Run tests.", "replace": "Run all tests.", "why": "Be specific."]
        let placed = try AIService.parse(try reply([specific]), request: single)
        XCTAssertEqual(placed.edits.map(\.content), ["# Rules\nRun all tests.\nShip it.\n"])
        XCTAssertEqual(placed.edits.first?.notes, [ChangeNote(line: 2, text: "Be specific.")])
        XCTAssertEqual(placed.edits.first?.baseBlob, agents.blob)
        XCTAssertEqual(placed.fileIDs, [agents.id])
        XCTAssertEqual(placed.status, "pending")
        // A repeated change counts once; one that doesn't match the file is listed instead of guessed.
        let missing = ["fileID": agents.id, "find": "Deploy daily.", "replace": "Deploy weekly.", "why": "Match the release cadence."]
        let partial = try AIService.parse(try reply([specific, specific, missing]), request: single)
        XCTAssertEqual(partial.edits.first?.notes.count, 1)
        XCTAssertTrue(partial.rationale.contains("Match the release cadence. (its text is not in the file)"), partial.rationale)
        // Text without a diff is not a proposal: nothing placed is an error the caller can retry.
        XCTAssertThrowsError(try AIService.parse(try reply([missing]), request: single)) { XCTAssertEqual($0 as? HarnessError, .unplaced(1)) }
        XCTAssertTrue(try AIService.parse(try reply([], summary: "Already clear."), request: single).edits.isEmpty)
        // With several files, a change names its file by ID or path, and an unknown file is listed, not guessed.
        let both = try await engine.prepareAnalysis(fileIDs: Set(inventory.files.map(\.id)))
        let claude = try XCTUnwrap(both.inputs.first { $0.path.hasSuffix("/CLAUDE.md") })
        let routed = try AIService.parse(try reply([["fileID": claude.path, "find": "Be brief.", "replace": "Be brief and exact.", "why": "Precision."],
                                                    ["fileID": "missing", "find": "Ship it.", "replace": "Ship.", "why": "Shorter."]]), request: both)
        XCTAssertEqual(routed.edits.map(\.fileID), [claude.fileID])
        XCTAssertTrue(routed.rationale.contains("Shorter. (names a file that is not in this request)"), routed.rationale)
        // Credentials, redaction markers, and malformed replies are refused outright.
        for unsafe in [["fileID": agents.id, "find": "Ship it.", "replace": "token = synthetic-not-real-secret", "why": "Add it."],
                       ["fileID": agents.id, "find": "Ship it.", "replace": "[REDACTED]", "why": "Hide it."]] {
            XCTAssertThrowsError(try AIService.parse(try reply([unsafe]), request: single), unsafe["replace"]!)
        }
        XCTAssertThrowsError(try AIService.parse(try reply([], summary: "Set api_key = Sup3rS3cretValue"), request: single))
        XCTAssertThrowsError(try AIService.parse("not-json", request: single))
    }

    func testDecisionsPersistAndKeptPointsReachLaterPrompts() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Rules\nRun tests.\n"); try fixture.write("CLAUDE.md", "# Claude\nBe brief.\n")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let files = try await engine.inventory().files
        let agents = try XCTUnwrap(files.first { $0.path == "AGENTS.md" }), claude = try XCTUnwrap(files.first { $0.path == "CLAUDE.md" })
        let request = try await engine.prepareAnalysis(fileIDs: [agents.id])
        let proposal = try await engine.analyze(request, runner: SpyRunner(output: try reply([["fileID": agents.id, "find": "Run tests.", "replace": "Run all tests.", "why": "Name the scope."]])))
        try await engine.keep(proposalID: proposal.id)
        let kept = try await engine.inventory()
        XCTAssertEqual(kept.proposals.map(\.status), ["kept"])
        // The kept point travels with later requests for that file, and only that file.
        let both = try await engine.prepareAnalysis(fileIDs: [agents.id, claude.id])
        XCTAssertEqual(both.kept, [agents.id: ["Name the scope."]])
        XCTAssertTrue(both.prompt.contains("Do not propose them again:\n- \(both.inputs[0].path): Name the scope."), both.prompt)
        XCTAssertEqual(try both.perFile().map { $0.prompt.contains("Name the scope.") }, [true, false])
        try await engine.reopen(proposalID: proposal.id)
        let reopened = try await engine.inventory()
        XCTAssertEqual(reopened.proposals.map(\.status), ["pending"])
        let fresh = try await engine.prepareAnalysis(fileIDs: [agents.id])
        XCTAssertTrue(fresh.kept.isEmpty)
        // A check marked fine stays fine across launches until shown again.
        try await engine.setDismissed(findingKey: "stale|file|missing/a.sh", true)
        let directory = await engine.store.directory
        XCTAssertEqual(try Store(directory: directory).inventory().dismissed, ["stale|file|missing/a.sh"])
        try await engine.setDismissed(findingKey: "stale|file|missing/a.sh", false)
        let shown = try await engine.inventory()
        XCTAssertTrue(shown.dismissed.isEmpty)
    }

    func testFixTasksNameTheFilesThatExist() async throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "Run `scripts/check.sh` and read `docs/setup.md`.")
        try fixture.write("tools/check.sh", "echo ok")
        try fixture.write("node_modules/pkg/setup.md", "dependency files are not candidates")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let findings = try await engine.findings().findings
        let finding = try XCTUnwrap(findings.first { $0.kind == "stale" })
        XCTAssertEqual(finding.missing, ["scripts/check.sh", "docs/setup.md"])
        let task = try await engine.fixInstructions(for: finding)
        XCTAssertTrue(task.contains("- `scripts/check.sh`: files with that name in the repository: `tools/check.sh`"), task)
        XCTAssertTrue(task.contains("- `docs/setup.md`: no file with that name exists in the repository"), task)
    }

    func testOneDiffWaitsPerFileAndRepeatsAreKnown() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Rules\nRun tests.\nShip it.\n"); try fixture.write("CLAUDE.md", "# Claude\nBe brief.\n")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let files = try await engine.inventory().files
        let agents = try XCTUnwrap(files.first { $0.path == "AGENTS.md" }), claude = try XCTUnwrap(files.first { $0.path == "CLAUDE.md" })
        func change(_ file: TrackedFile, _ find: String, _ replace: String) throws -> SpyRunner {
            SpyRunner(output: try reply([["fileID": file.id, "find": find, "replace": replace, "why": "Clearer."]]))
        }
        let request = try await engine.prepareAnalysis(fileIDs: [agents.id])
        XCTAssertTrue(request.repeats.isEmpty)
        let first = try await engine.analyze(request, runner: try change(agents, "Run tests.", "Run all tests."))
        let other = try await engine.analyze(try await engine.prepareAnalysis(fileIDs: [claude.id]), runner: try change(claude, "Be brief.", "Be brief and exact."))
        // The same content with the same task is a repeat; other instructions are a new question.
        let again = try await engine.prepareAnalysis(fileIDs: [agents.id, claude.id])
        XCTAssertEqual(Set(again.repeats), [agents.id, claude.id])
        XCTAssertTrue(try again.with(instructions: "Only fix typos.").repeats.isEmpty)
        let trimmed = try again.without([claude.id])
        XCTAssertEqual(trimmed.inputs.map(\.fileID), [agents.id])
        XCTAssertFalse(trimmed.prompt.contains("Be brief."))
        // A newer diff for a file replaces the one waiting; other files' diffs stay.
        let second = try await engine.analyze(try await engine.prepareAnalysis(fileIDs: [agents.id]), runner: try change(agents, "Ship it.", "Ship after review."))
        let statuses = Dictionary(uniqueKeysWithValues: try await engine.inventory().proposals.map { ($0.id, $0.status) })
        XCTAssertEqual(statuses, [first.id: "replaced", other.id: "pending", second.id: "pending"])
        // Changed content is new work.
        try fixture.write("AGENTS.md", "# Rules\nRun every test.\n"); _ = try await engine.scan()
        let changed = try await engine.prepareAnalysis(fileIDs: [agents.id])
        XCTAssertTrue(changed.repeats.isEmpty)
    }

    func testOnlyDiffsReachTheInbox() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let file = try await engine.inventory().files[0]
        let request = try await engine.prepareAnalysis(fileIDs: [file.id])
        // A file that needs nothing is reported, not stored.
        let nothing = try await engine.analyze(request, runner: SpyRunner(output: try reply([], summary: "Already clear.")))
        XCTAssertTrue(nothing.edits.isEmpty)
        var inventory = try await engine.inventory()
        XCTAssertTrue(inventory.proposals.isEmpty)
        XCTAssertEqual(inventory.invocations.first?.status, "completed")
        // Text-only recommendations from earlier versions stay stored but out of the inbox.
        try await engine.store.save(Proposal(model: "fixture", rationale: "Say which tests to run.", edits: [], note: "fixture", fileIDs: [file.id]))
        let diff = try await engine.analyze(request, runner: SpyRunner(output: try response(for: request)))
        inventory = try await engine.inventory()
        XCTAssertEqual(inventory.proposals.map(\.id), [diff.id])
    }

    func testOpenCodeInvocationIsIsolatedAndToolDenied() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        var settings = try await engine.settings(); settings.backend = "opencode"; settings.binary = "/opt/homebrew/bin/opencode"
        try await engine.save(settings: settings)
        let inventory = try await engine.inventory(), request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "text", "part": ["text": try response(for: request)]]), as: UTF8.self)
        let runner = SpyRunner(output: output)
        let userConfig = fixture.root.appendingPathComponent("xdg/opencode")
        try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
        try Data("""
        {
          // Provider definitions survive isolation; everything else stays behind.
          "provider": {"zai": {"options": {"apiKey": "{file:./zai.key}"}}},
          "model": "zai/glm-4.6",
          "mcp": {"local": {"type": "local", "command": ["untrusted"]}},
          "plugin": ["untrusted-plugin"],
        }
        """.utf8).write(to: userConfig.appendingPathComponent("opencode.jsonc"))
        _ = try await AIService.run(request, runner: runner, environment: ["XDG_CONFIG_HOME": fixture.root.appendingPathComponent("xdg").path])
        let calls = await runner.requests()
        XCTAssertTrue(calls[0].arguments.contains("--standalone"))
        XCTAssertTrue(calls[0].environment["OPENCODE_CONFIG_CONTENT"]!.contains("deny"))
        XCTAssertEqual(calls[0].environment["OPENCODE_PERMISSION"], "{\"*\":\"deny\"}")
        XCTAssertEqual(calls[0].environment["OPENCODE_DISABLE_CLAUDE_CODE"], "true")
        XCTAssertEqual(calls[0].environment["OPENCODE_PURE"], "true")
        XCTAssertEqual(calls[0].environment["XDG_CONFIG_HOME"], calls[0].directory.appendingPathComponent("config").path)
        let configs = await runner.openCodeConfigs()
        let config = try XCTUnwrap(configs.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "zai/glm-4.6")
        XCTAssertEqual((object["mcp"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((object["plugin"] as? [Any])?.isEmpty, true)
        XCTAssertEqual((object["permission"] as? [String: String])?["*"], "deny")
        let key = ((object["provider"] as? [String: Any])?["zai"] as? [String: Any]).flatMap { $0["options"] as? [String: Any] }?["apiKey"] as? String
        XCTAssertEqual(key, "{file:" + userConfig.path + "/./zai.key}")
        XCTAssertThrowsError(try AIService.extractOpenCode("{\"type\":\"error\"}"))
    }

    func testJSONCIsStrippedWithoutTouchingStrings() throws {
        let jsonc = Data("""
        { "url": "https://example.com/a//b", /* block */ "list": [1, 2,], // tail
          "text": "/* not a comment */ \\" // still text",
        }
        """.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: AIService.stripJSONComments(jsonc)) as? [String: Any])
        XCTAssertEqual(object["url"] as? String, "https://example.com/a//b")
        XCTAssertEqual(object["text"] as? String, "/* not a comment */ \" // still text")
        XCTAssertEqual(object["list"] as? [Int], [1, 2])
    }

    func testRepliesWithPrefaceOrFencesStillParse() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id])
        let json = try response(for: request)
        for reply in ["Here is the analysis:\n" + json, "```json\n" + json + "\n```", "Sure.\n```\n" + json + "\n```\nDone."] {
            XCTAssertEqual(try AIService.parse(reply, request: request).edits.count, 1, reply)
        }
    }

    func testRepositoryNamesWithDeniedWordsCanReceiveProposals() async throws {
        let fixture = try Fixture()
        let repo = fixture.root.appendingPathComponent("named/keychain-sync")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("# Sync\nRun tests.\n".utf8).write(to: repo.appendingPathComponent("AGENTS.md"))
        let engine = try Engine(directory: fixture.root.appendingPathComponent("store"))
        var settings = AppSettings(); settings.roots = [fixture.root.appendingPathComponent("named").path]
        try await engine.save(settings: settings); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let request = try await engine.prepareAnalysis(fileIDs: Set(inventory.files.map(\.id)))
        XCTAssertEqual(try AIService.parse(try response(for: request), request: request).edits.count, 1)
    }

    func testExecPoliciesAndMemoriesStayLocal() async throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "# Safe\nRun tests.")
        try fixture.write(".codex/rules/default.rules", "prefix_rule(pattern=[\"ls\"], decision=\"allow\")")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let rules = try XCTUnwrap(inventory.files.first { $0.path == ".codex/rules/default.rules" })
        XCTAssertEqual(rules.category, "config")
        let request = try await engine.prepareAnalysis(fileIDs: Set(inventory.files.map(\.id)))
        XCTAssertEqual(request.inputs.count, 1)
        XCTAssertTrue(request.excluded.contains { $0.contains("default.rules") })
        // A proposal targeting the policy is refused even when stored by other means.
        let proposal = Proposal(model: "fixture", rationale: "example", edits: [ProposalEdit(fileID: rules.id, baseBlob: rules.blob!, content: "prefix_rule(pattern=[\"rm\"], decision=\"allow\")")], note: "fixture")
        try await engine.store.save(proposal)
        do { try await engine.accept(proposalID: proposal.id); XCTFail("Exec policy edited") }
        catch { XCTAssertEqual(error as? HarnessError, .conflict) }
    }

    func testPayloadSizeLimitAppliesToEachRequest() async throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", String(repeating: "word ", count: 30000))
        try fixture.write("CLAUDE.md", String(repeating: "small ", count: 4000))
        try fixture.write("docs/AGENTS.md", String(repeating: "small ", count: 4000))
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let big = try XCTUnwrap(inventory.files.first { $0.path == "AGENTS.md" })
        let oversized = try await engine.prepareAnalysis(fileIDs: [big.id])
        XCTAssertNotNil(oversized.sizeProblem(oneByOne: true))
        do { _ = try await AIService.run(oversized, runner: SpyRunner(output: "")); XCTFail("Payload should be bounded") } catch {}
        // Two files that fit only one at a time: together is refused, one by one is fine.
        let small = Set(inventory.files.filter { $0.path != "AGENTS.md" }.map(\.id))
        let pair = try await engine.prepareAnalysis(fileIDs: small)
        XCTAssertNil(pair.sizeProblem(oneByOne: true))
        XCTAssertEqual(try pair.perFile().map(\.inputs.count), [1, 1])
        XCTAssertTrue(try pair.perFile().allSatisfy { $0.bytes < pair.bytes })
    }

    func testExpiredProposalIsNotApplied() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "original")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        var proposal = Proposal(model: "fixture", rationale: "example", edits: [ProposalEdit(fileID: inventory.files[0].id, baseBlob: inventory.files[0].blob!, content: "changed")], note: "fixture")
        proposal.createdAt = Date().addingTimeInterval(-31 * 86400)
        try await engine.store.save(proposal)
        do { try await engine.accept(proposalID: proposal.id); XCTFail("Expired proposal applied") } catch {}
        let after = try await engine.inventory()
        XCTAssertEqual(after.proposals[0].status, "expired")
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "original")
    }

    func testBatchWriteFailureRollsBackEarlierFile() async throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "first"); try fixture.write("CLAUDE.md", "second")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        let inventory = try await engine.inventory()
        let files = inventory.files.sorted { $0.path < $1.path }
        let edits = files.map { ProposalEdit(fileID: $0.id, baseBlob: $0.blob!, content: "replacement") }
        let proposal = Proposal(model: "fixture", rationale: "example", edits: edits, note: "fixture")
        try await engine.store.save(proposal)
        try FileManager.default.linkItem(at: fixture.repo.appendingPathComponent("CLAUDE.md"), to: fixture.root.appendingPathComponent("hardlink"))
        do { try await engine.accept(proposalID: proposal.id); XCTFail("Hard-linked target accepted") } catch {}
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("AGENTS.md"), encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "second")
        let after = try await engine.inventory()
        XCTAssertEqual(after.proposals[0].status, "pending")
        XCTAssertEqual(after.versions.filter { $0.origin == "pre_apply" }.count, 2)
        XCTAssertTrue(after.versions.contains { $0.origin == "rollback" })
    }
}

@MainActor final class ProcessRunnerTests: XCTestCase {
    func testRealProcessReadsStdinWithoutPipeDeadlock() async throws {
        let fixture = try Fixture()
        let input = Data(String(repeating: "sample ", count: 20000).utf8)
        let request = ProcessRequest(binary: "/bin/cat", arguments: [], directory: fixture.root, environment: [:], input: input, timeout: 2)
        let result = try await CLIProcessRunner().run(request)
        XCTAssertEqual(Data(result.utf8), input)
    }
    func testProcessTimeoutAndNonzeroExitAreErrors() async throws {
        for (binary, arguments) in [("/bin/sleep", ["2"]), ("/usr/bin/false", [])] {
            let fixture = try Fixture()
            let request = ProcessRequest(binary: binary, arguments: arguments, directory: fixture.root, environment: [:], input: Data(), timeout: 0.1)
            do { _ = try await CLIProcessRunner().run(request); XCTFail("Process must fail or time out") }
            catch {
                XCTAssertTrue(error is HarnessError)
                if binary == "/bin/sleep" { XCTAssertTrue(error.localizedDescription.contains("was silent for"), error.localizedDescription) }
            }
        }
    }
    func testSteadyOutputKeepsAProcessAliveBeyondTheTimeout() async throws {
        let fixture = try Fixture()
        // Runs about 0.8 s against a 0.4 s timeout, but never goes quiet for that long.
        let request = ProcessRequest(binary: "/bin/sh", arguments: ["-c", "for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 0.1; done"], directory: fixture.root,
                                     environment: [:], input: Data(), timeout: 0.4)
        let output = try await CLIProcessRunner().run(request)
        XCTAssertEqual(output.split(separator: "\n").count, 8)
        var capped = request; capped.runLimit = 0.3
        do { _ = try await CLIProcessRunner().run(capped); XCTFail("The run limit must stop it") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still running"), error.localizedDescription) }
    }
    func testCancellationStopsRunningProcess() async throws {
        let fixture = try Fixture()
        let request = ProcessRequest(binary: "/bin/sleep", arguments: ["5"], directory: fixture.root, environment: [:], input: Data(), timeout: 10)
        let started = Date()
        let task = Task { try await CLIProcessRunner().run(request) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process succeeded") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
