import XCTest
@testable import HarnessKit

/// Records CLI calls; for Codex it writes the reply to the `-o` file, like the real CLI.
private actor RecordingRunner: ProcessRunning {
    var calls: [ProcessRequest] = []
    var schemaSeen = false
    let reply: String
    init(reply: String) { self.reply = reply }
    func run(_ request: ProcessRequest) async throws -> String {
        calls.append(request)
        if let flag = request.arguments.firstIndex(of: "-o"), flag + 1 < request.arguments.count {
            if let schema = request.arguments.firstIndex(of: "--output-schema") { schemaSeen = FileManager.default.fileExists(atPath: request.arguments[schema + 1]) }
            try Data(reply.utf8).write(to: URL(fileURLWithPath: request.arguments[flag + 1]))
            return "progress lines that are not the answer"
        }
        return reply
    }
    func requests() -> [ProcessRequest] { calls }
    func sawSchema() -> Bool { schemaSeen }
}

private actor RecordingHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    let reply: Data
    let status: Int
    let failure: URLError?
    init(reply: Data, status: Int = 200, failure: URLError? = nil) { self.reply = reply; self.status = status; self.failure = failure }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        return (reply, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func sent() -> [URLRequest] { requests }
}

/// Answers with each reply in turn, like a server that refuses the first form of a request.
private actor SequenceHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, Data)]
    init(replies: [(Int, Data)]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data) = replies.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func sent() -> [URLRequest] { requests }
}

@MainActor final class BackendTests: XCTestCase {
    private func request(backend: String, model: String = "", effort: String = "", thorough: Bool = false) async throws -> (AnalysisRequest, Fixture) {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "# Project\nRun tests.")
        let engine = try await fixture.engine(); _ = try await engine.scan()
        var settings = try await engine.settings()
        settings.backend = backend; settings.binary = "/opt/homebrew/bin/" + backend; settings.model = model; settings.effort = effort
        settings.thoroughAnalysis = thorough
        try await engine.save(settings: settings)
        let inventory = try await engine.inventory()
        return (try await engine.prepareAnalysis(fileIDs: [inventory.files[0].id]), fixture)
    }

    private func reply(for request: AnalysisRequest, edits: Bool = true) -> String {
        let input = request.inputs[0]
        let change = "{\"fileID\":\"\(input.fileID)\",\"find\":\"Run tests.\",\"replace\":\"Run all tests.\",\"why\":\"Keep tests explicit.\"}"
        return "{\"summary\":\"Name the tests to run.\",\"changes\":[\(edits ? change : "")]}"
    }

    func testCodexRunsIsolatedReadOnlyAndReadsTheLastMessageFile() async throws {
        let (request, fixture) = try await request(backend: "codex", model: "gpt-test", effort: "high", thorough: true)
        _ = fixture
        let runner = RecordingRunner(reply: reply(for: request))
        let proposal = try await AIService.run(request, runner: runner)
        let calls = await runner.requests()
        let arguments = try XCTUnwrap(calls.first).arguments
        XCTAssertEqual(arguments.first, "exec")
        XCTAssertEqual(arguments.last, "-")
        for expected in [["--sandbox", "read-only"], ["--model", "gpt-test"], ["-c", "model_reasoning_effort=\"high\""], ["--disable", "computer_use"]] {
            XCTAssertNotNil(arguments.indices.first { arguments[$0...].starts(with: expected) }, "\(expected)")
        }
        for flag in ["--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--output-schema", "-o"] { XCTAssertTrue(arguments.contains(flag), flag) }
        let sawSchema = await runner.sawSchema()
        XCTAssertTrue(sawSchema)
        XCTAssertEqual(proposal.edits.count, 1)
        XCTAssertEqual(proposal.model, "codex/gpt-test (high)")
    }

    func testClaudeEffortAndOpenCodeVariant() async throws {
        let (claude, first) = try await request(backend: "claude", effort: "max", thorough: true)
        _ = first
        let claudeRunner = RecordingRunner(reply: reply(for: claude))
        _ = try await AIService.run(claude, runner: claudeRunner)
        let claudeCalls = await claudeRunner.requests()
        let claudeArguments = try XCTUnwrap(claudeCalls.first).arguments
        XCTAssertTrue(claudeArguments.indices.contains { claudeArguments[$0...].starts(with: ["--effort", "max"]) })
        XCTAssertTrue(claudeArguments.indices.contains { claudeArguments[$0...].starts(with: ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]) })

        let (opencode, second) = try await request(backend: "opencode", model: "openai/gpt-test", effort: "high")
        _ = second
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "text", "part": ["text": reply(for: opencode)]]), as: UTF8.self)
        let openCodeRunner = RecordingRunner(reply: line)
        _ = try await AIService.run(opencode, runner: openCodeRunner, environment: [:])
        let openCodeCalls = await openCodeRunner.requests()
        let openCodeArguments = try XCTUnwrap(openCodeCalls.first).arguments
        XCTAssertTrue(openCodeArguments.indices.contains { openCodeArguments[$0...].starts(with: ["--model", "openai/gpt-test#high"]) })
    }

    func testOllamaSendsSchemaContextAndThinkingToTheLocalServer() async throws {
        var (request, fixture) = try await request(backend: "ollama", model: "gemma4:e4b", effort: "high", thorough: true)
        _ = fixture
        request.settings.ollamaURL = "http://127.0.0.1:11434/"
        let body = try JSONSerialization.data(withJSONObject: ["response": reply(for: request), "done": true])
        let http = RecordingHTTP(reply: body)
        let proposal = try await AIService.run(request, http: http)
        let requests = await http.sent()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "gemma4:e4b")
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(payload["think"] as? String, "high")
        XCTAssertNotNil(payload["format"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(((payload["options"] as? [String: Any])?["num_ctx"] as? Int) ?? 0, 8192)
        XCTAssertEqual(proposal.edits.count, 1)
        XCTAssertTrue(proposal.note.contains("local Ollama"))

        request.settings.effort = "off"
        let quiet = RecordingHTTP(reply: body)
        _ = try await AIService.run(request, http: quiet)
        let quietRequests = await quiet.sent()
        let quietPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(quietRequests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(quietPayload["think"] as? Bool, false)

        let down = RecordingHTTP(reply: Data(), failure: URLError(.cannotConnectToHost))
        do { _ = try await AIService.run(request, http: down); XCTFail("Unreachable server must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not reachable"), error.localizedDescription) }
    }

    func testQuickDepthSkipsExtendedThinking() async throws {
        let (claude, first) = try await request(backend: "claude", effort: "max")
        _ = first
        let claudeRunner = RecordingRunner(reply: reply(for: claude))
        let proposal = try await AIService.run(claude, runner: claudeRunner)
        let claudeCalls = await claudeRunner.requests()
        let arguments = try XCTUnwrap(claudeCalls.first).arguments
        XCTAssertTrue(arguments.indices.contains { arguments[$0...].starts(with: ["--effort", "low"]) }, "\(arguments)")
        XCTAssertTrue(proposal.note.hasPrefix("Quick analysis"))
        XCTAssertEqual(proposal.model, "claude/CLI default (low)")

        var (local, second) = try await request(backend: "ollama", model: "gemma4:12b", effort: "high")
        _ = second
        local.settings.ollamaURL = "http://127.0.0.1:11434"
        let http = RecordingHTTP(reply: try JSONSerialization.data(withJSONObject: ["response": reply(for: local), "done": true]))
        _ = try await AIService.run(local, http: http)
        let localRequests = await http.sent()
        let sent = try XCTUnwrap(localRequests.first?.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: sent) as? [String: Any])?["think"] as? Bool, false)

        let (codex, third) = try await request(backend: "codex", effort: "xhigh")
        _ = third
        let codexRunner = RecordingRunner(reply: reply(for: codex))
        _ = try await AIService.run(codex, runner: codexRunner)
        let codexCalls = await codexRunner.requests()
        XCTAssertTrue(try XCTUnwrap(codexCalls.first).arguments.contains("model_reasoning_effort=\"low\""))
        // OpenCode variants depend on the model, so quick keeps the configured one.
        XCTAssertNil(AIService.quickEffort(for: "opencode"))
    }

    func testClaudeStreamYieldsTheFinalResultAndReportsErrors() throws {
        func line(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        let events = [try line(["type": "system", "subtype": "init"]),
                      try line(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "{\"summary\""]]]),
                      try line(["type": "result", "subtype": "success", "is_error": false, "result": "{\"summary\": \"ok\", \"changes\": []}"])]
        XCTAssertEqual(try AIService.extractClaude(events.joined(separator: "\n")), "{\"summary\": \"ok\", \"changes\": []}")
        XCTAssertEqual(try AIService.extractClaude("plain text answer"), "plain text answer")
        let failed = try line(["type": "result", "subtype": "success", "is_error": true, "result": "Usage limit reached"])
        XCTAssertThrowsError(try AIService.extractClaude(failed)) { XCTAssertTrue($0.localizedDescription.contains("Usage limit reached"), $0.localizedDescription) }
    }

    func testOllamaJoinsStreamedChunksAndReportsStreamFailures() async throws {
        var (request, fixture) = try await request(backend: "ollama", model: "gemma4:12b")
        _ = fixture
        request.settings.ollamaURL = "http://127.0.0.1:11434"
        func line(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        let answer = reply(for: request)
        let middle = answer.index(answer.startIndex, offsetBy: answer.count / 2)
        let chunks = [try line(["thinking": "Reading the file", "response": "", "done": false]),
                      try line(["response": String(answer[..<middle]), "done": false]),
                      try line(["response": String(answer[middle...]), "done": false]),
                      try line(["response": "", "done": true, "done_reason": "stop"])]
        let proposal = try await AIService.run(request, http: RecordingHTTP(reply: Data(chunks.joined(separator: "\n").utf8)))
        XCTAssertEqual(proposal.edits.count, 1)

        let failures: [(String, String)] = [
            ([chunks[1], try line(["error": "model runner has unexpectedly stopped"])].joined(separator: "\n"), "Ollama stopped: model runner has unexpectedly stopped"),
            (chunks[1], "closed the connection"),
        ]
        for (body, expected) in failures {
            do { _ = try await AIService.run(request, http: RecordingHTTP(reply: Data(body.utf8))); XCTFail("Must fail: \(expected)") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
        request.settings.timeout = 120
        do { _ = try await AIService.run(request, http: RecordingHTTP(reply: Data(), failure: URLError(.timedOut))); XCTFail("Silence must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("sent nothing for 120 s"), error.localizedDescription) }
    }

    func testChangesThatDontMatchGetOneMoreTry() async throws {
        var (request, fixture) = try await request(backend: "ollama", model: "gemma4:12b")
        _ = fixture
        request.settings.ollamaURL = "http://127.0.0.1:11434"
        let input = request.inputs[0]
        let misquoted = "{\"summary\":\"x\",\"changes\":[{\"fileID\":\"\(input.fileID)\",\"find\":\"Run every test.\",\"replace\":\"y\",\"why\":\"z\"}]}"
        func body(_ answer: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["response": answer, "done": true]) }
        let recovering = SequenceHTTP(replies: [(200, try body(misquoted)), (200, try body(reply(for: request)))])
        let proposal = try await AIService.run(request, http: recovering)
        XCTAssertEqual(proposal.edits.count, 1)
        let tries = await recovering.sent()
        XCTAssertEqual(tries.count, 2)
        let failing = SequenceHTTP(replies: [(200, try body(misquoted)), (200, try body(misquoted))])
        do { _ = try await AIService.run(request, http: failing); XCTFail("Two misses must fail") }
        catch { XCTAssertEqual(error as? HarnessError, .unplaced(1)); XCTAssertTrue(error.localizedDescription.contains("didn't match the file text")) }
    }

    func testOllamaRetriesWithoutSchemaWhenTheModelCannotConstrainOutput() async throws {
        var (request, fixture) = try await request(backend: "ollama", model: "gemma4:e4b")
        _ = fixture
        request.settings.ollamaURL = "http://127.0.0.1:11434"
        let refusal = try JSONSerialization.data(withJSONObject: ["error": "structured output is unavailable"])
        let answer = try JSONSerialization.data(withJSONObject: ["response": "Here it is:\n" + reply(for: request), "done": true])
        let http = SequenceHTTP(replies: [(501, refusal), (200, answer)])
        let proposal = try await AIService.run(request, http: http)
        XCTAssertEqual(proposal.edits.count, 1)
        let sent = await http.sent()
        XCTAssertEqual(sent.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent[0].httpBody)) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent[1].httpBody)) as? [String: Any])
        XCTAssertNotNil(first["format"])
        XCTAssertNil(second["format"])
    }

    func testModelDiscovery() async throws {
        var settings = AppSettings(); settings.backend = "ollama"
        let tags = try JSONSerialization.data(withJSONObject: ["models": [["name": "gemma4:12b"], ["name": "gemma4:e4b"]]])
        let models = try await AIService.models(for: settings, http: RecordingHTTP(reply: tags))
        XCTAssertEqual(models, ["gemma4:12b", "gemma4:e4b"])
        XCTAssertEqual(AIService.configuredModels(in: "model = \"gpt-a\"\n[profiles.fast]\nmodel = \"gpt-b\"\nmodel_reasoning_effort = \"low\"\n"), ["gpt-a", "gpt-b"])
        settings.backend = "opencode"; settings.binary = "/opt/homebrew/bin/opencode"
        let listed = try await AIService.models(for: settings, runner: RecordingRunner(reply: "Available models:\nanthropic/claude-sonnet\nopenai/gpt-test\n"))
        XCTAssertEqual(listed, ["anthropic/claude-sonnet", "openai/gpt-test"])
        settings.backend = "claude"
        let aliases = try await AIService.models(for: settings)
        XCTAssertTrue(aliases.contains("opus"))
    }

    func testInstructionsShapeThePromptThatAsksForChanges() async throws {
        let (request, fixture) = try await request(backend: "claude")
        _ = fixture
        let focused = try request.with(instructions: "Focus on test guidance only.")
        XCTAssertTrue(focused.prompt.contains("Focus on test guidance only."))
        XCTAssertTrue(focused.prompt.contains("\"find\""))
        // The model gets IDs and text only; the base hash stays with the request.
        XCTAssertFalse(focused.prompt.contains(request.inputs[0].baseBlob))
        let proposal = try AIService.parse(reply(for: focused), request: focused)
        XCTAssertEqual(proposal.edits.first?.content, "# Project\nRun all tests.")
        XCTAssertEqual(proposal.instructions, "Focus on test guidance only.")
        XCTAssertTrue(try AIService.parse(reply(for: focused, edits: false), request: focused).edits.isEmpty)
        XCTAssertTrue(request.prompt.contains(AIService.defaultInstructions))
        XCTAssertThrowsError(try request.with(instructions: "Use api_key = Sup3rS3cretValue"))
    }

    func testRejectsUnsafeModelNamesAndOllamaWithoutModel() async throws {
        let (spaced, first) = try await request(backend: "claude", model: "bad model")
        _ = first
        do { _ = try await AIService.run(spaced, runner: RecordingRunner(reply: "")); XCTFail("A model with spaces must be refused") } catch {}
        let (local, second) = try await request(backend: "ollama")
        _ = second
        do { _ = try await AIService.run(local, http: RecordingHTTP(reply: Data())); XCTFail("Ollama needs a model") }
        catch { XCTAssertEqual(error as? HarnessError, .invalid("Choose an installed Ollama model.")) }
        XCTAssertTrue(AIService.isLoopback("http://localhost:11434"))
        XCTAssertFalse(AIService.isLoopback("http://192.168.1.20:11434"))
    }
}
