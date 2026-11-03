import XCTest
@testable import HarnessKit

final class PrivacyTests: XCTestCase {
    func testDenylist() {
        for path in ["auth.json", ".claude.json", "nested/credentials.txt", "foo/KEYCHAIN.db", "tls.pem", "dev.auto.tfvars", "prod.auto.tfvars.json", ".env.local", ".envrc", "private.key", "id_ed25519", "release.keystore", "app.jks"] {
            XCTAssertTrue(Privacy.denied(path), path)
        }
        for path in ["AGENTS.md", "skills/check/SKILL.md", ".codex/config.toml", ".claude/settings.json", "environment.md"] {
            XCTAssertFalse(Privacy.denied(path), path)
        }
    }

    func testCredentialSniffingAndRedaction() throws {
        // Fake credentials, joined at run time so secret scanners and push protection don't take them for real ones.
        let begin = "-----BEGIN ", privateKey = "PRIVATE KEY-----"
        for text in ["api_key = \"not-a-real-synthetic-secret\"", "{\"password\": \"test-password-value\"}",
                     begin + privateKey + "\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END " + privateKey,
                     "{\"private_key\": \"" + begin + privateKey + "\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\\n\"}",
                     "key: |\n  " + begin + "RSA " + privateKey + "\n  Proc-Type: 4,ENCRYPTED\n  DEK-Info: AES-128-CBC,0A1B2C3D\n\n  MIIEpAIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gunVTLw\n",
                     "https://deploy:Zq7rT2mW9x@example.invalid", "sk-proj-abcdefghijklmnopqrstuvwx",
                     "aws_secret_access_key = " + "q3Vt8NcRw2LkHy6PjZ0s" + "XbE4mFa9GuTd1oYiKe5W", "password = MyPassword123", "client_secret: Xk2-pq9-zzRt",
                     "webhook_secret = plain-words-but-digits9", "api_key: synthetic_value_one", "SLACK_BOT_TOKEN=xoxb-" + "123456789012-abcdefghijklmnop", "DB_PASSWORD=Sup3rS3cret!",
                     "postgres://app:Sup3rS3cret@db.internal:5432/app", "github_" + "pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz",
                     "password = correct-horse-battery-staple", "Bearer " + "Zx8fKp2qLmNvBc4t" + "Rw7yHs1dGj6uEa9oTi3kWe5n", "secret: " + "9f86d081884c7d65" + "9a2feaa0c55ad015",
                     ["eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ", "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"].joined(separator: ".")] {
            XCTAssertGreaterThan(Privacy.redacted(text).count, 0, text)
            XCTAssertThrowsError(try Privacy.validate(Data(text.utf8), path: "renamed.md"))
        }
        let opaque = "aZ9kD4pR7xM2bH6vN8tQ1sW5eF3uJ0cL9gY2iA7oS4dX6rB8"
        XCTAssertGreaterThan(Privacy.redacted(opaque).count, 0)
        XCTAssertEqual(Privacy.redacted("key: \(opaque) and token: \(opaque)").text, "key: [REDACTED] and token: [REDACTED]")
        XCTAssertNoThrow(try Privacy.validate(Data("# Instructions\nUse small changes and run tests.\n".utf8), path: "AGENTS.md"))
        XCTAssertEqual(Privacy.redacted(String(repeating: "a", count: 64)).count, 0)
    }

    func testPlaceholdersAndDocumentedExamplesAreNotSecrets() {
        for text in [
            "export AWS_SECRET_ACCESS_KEY=your_secret",
            "api_key: YOUR_API_KEY",
            "client_secret = \"yourClientSecret\"",
            "token: my-token-here",
            "password = changeme",
            "secret: xxxx_xxxxxx",
            "DB_PASSWORD=secret_password",
            "DATABASE_URL=postgres://user:password@localhost:5432/app",
            "git clone https://oauth2:your_token@gitlab.example.com/team/repo.git",
            "OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx",
            "GITHUB_TOKEN=ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
            "aws_access_key_id = AKIAIOSFODNN7EXAMPLE",
            "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        ] {
            XCTAssertEqual(Privacy.redacted(text).count, 0, text)
        }
    }

    func testBlockedContentNamesTheLineAndRuleButNotTheValue() {
        let text = "# Setup\nExport the key:\nDB_PASSWORD=Sup3rS3cret!\n"
        XCTAssertThrowsError(try Privacy.validate(Data(text.utf8), path: "AGENTS.md")) { error in
            XCTAssertEqual(error as? HarnessError, .sensitive(path: "AGENTS.md", line: 3, reason: "a credential assigned to DB_PASSWORD"))
            XCTAssertFalse(error.localizedDescription.contains("Sup3r"))
        }
        XCTAssertThrowsError(try Privacy.validate(Data("ok\nghp_abcdefghijklmnopqrstuvwxyz0123".utf8), path: "CLAUDE.md")) { error in
            XCTAssertEqual(error as? HarnessError, .sensitive(path: "CLAUDE.md", line: 2, reason: "an API token"))
        }
    }

    func testOrdinaryInstructionTextIsNotTreatedAsSecret() {
        for text in [
            "Pin actions: `uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`",
            "Regression introduced in 3f786850e387550fdab836ed7e6dc881de23001b.",
            "Image: `alpine@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1`",
            "Configure `password: \"$DB_PASSWORD\"` from the environment.",
            "Read it with `api_key = os.environ[\"API_KEY\"]`.",
            "Use `token: ${{ secrets.GITHUB_TOKEN }}` in workflows.",
            "secretName: tls-certificate-production",
            "password: required",
            "Run `swift test --filter testSnapshotV2EncodingIsDeterministicAcrossRuns`.",
            "[projects.\"/Users/me/Personal/2026-08-05T15-48-34-xavo-argocd_cicd_team_production_project_access\"]",
            "Temp files live in /private/var/folders/j1/y22wdfzd1k17vhl9kf6v5frc0000gp/T/harnessmd-test-D470528F-5882-483A-9A22-DA6BA92CEA87",
            "\"integrity\": \"sha512-Qm4dCLPpSXFqWeTUJbHuHnHyIwvbXnUpAEq5FRVm0rRs7vP9kGcO3xlbSUs5QvGA5qX1A8fUDuQx3HNJ5Qr6Q==\"",
            "[projects.\"/Users/me/.workspaces/app-main/3f9a1c7e5b2d4a6f8c0e1b3d5f7a9c2e\"]",
            "rollout_summary_file: 2026-10-20T10-37-42-OTCk-prod_ah_ams1_my_bets_redis_9x9_12gi.md",
            "- Secrets: `redis-tls-user-crt`, existingSecret: harbor-admin-secret",
            "Set `passwordProperty: vault-field` in the chart values.",
            "Never commit a literal `-----BEGIN RSA " + "PRIVATE KEY-----` block; mount it from a secret.",
            "Set `githubConfigSecret: arc-github-app` and `tlsSecret: wildcard-tls-cert`.",
            "-----BEGIN OPENSSH " + "PRIVATE KEY----- headers mean a key was pasted.",
            "- The installer's SHA-256 is `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`; keep it pinned.",
            "Published SHA-256: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.",
            "Use `token: abc` style keys, as in `password: hunter`.",
        ] {
            XCTAssertEqual(Privacy.redacted(text).count, 0, text)
        }
    }

    func testBinaryAndOversizeAreRejected() {
        XCTAssertThrowsError(try Privacy.validate(Data([0xff, 0x00]), path: "SKILL.md"))
        XCTAssertThrowsError(try Privacy.validate(Data(repeating: 97, count: Privacy.maxFileBytes + 1), path: "SKILL.md"))
    }

    func testTraversalAndSymlinkReadWriteAreRejected() throws {
        let fixture = try Fixture()
        for path in ["../AGENTS.md", "a/../b", "/etc/hosts", "a//b", "a/./b", ""] {
            XCTAssertThrowsError(try SafeFiles.components(path))
        }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try SafeFiles.read(root: fixture.repo.path, path: "link/AGENTS.md"))
        XCTAssertThrowsError(try SafeFiles.write(Data(), root: fixture.repo.path, path: "link/AGENTS.md"))
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent("AGENTS.md"), withDestinationURL: outside.appendingPathComponent("AGENTS.md"))
        XCTAssertThrowsError(try SafeFiles.read(root: fixture.repo.path, path: "AGENTS.md"))
        XCTAssertThrowsError(try SafeFiles.write(Data(), root: fixture.repo.path, path: "AGENTS.md"))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("AGENTS.md"), encoding: .utf8), "untouched")
    }

    func testRestoreRejectsHardLinks() throws {
        let fixture = try Fixture()
        try fixture.write("AGENTS.md", "original")
        try FileManager.default.linkItem(at: fixture.repo.appendingPathComponent("AGENTS.md"), to: fixture.root.appendingPathComponent("hard-link"))
        XCTAssertThrowsError(try SafeFiles.write(Data("changed".utf8), root: fixture.repo.path, path: "AGENTS.md"))
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("hard-link"), encoding: .utf8), "original")
    }

    func testSkillWithDeniedOrSymlinkedBundleIsRejectedAsAUnit() throws {
        let fixture = try Fixture()
        try fixture.write(".claude/skills/check/SKILL.md", "# Check")
        try fixture.write(".claude/skills/check/prod.auto.tfvars", "sensitive")
        let skill = TrackedFile(sourceID: fixture.source.id, path: ".claude/skills/check", category: "skills", tool: "claude", isDirectory: true)
        XCTAssertThrowsError(try SafeFiles.capture(root: fixture.repo.path, file: skill)) { XCTAssertEqual($0 as? HarnessError, .blocked(".claude/skills/check/prod.auto.tfvars")) }
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".claude/skills/check/prod.auto.tfvars"))
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent(".claude/skills/check/ref"), withDestinationURL: fixture.repo.appendingPathComponent(".git"))
        XCTAssertThrowsError(try SafeFiles.capture(root: fixture.repo.path, file: skill)) { XCTAssertEqual($0 as? HarnessError, .unsafePath(".claude/skills/check/ref")) }
    }

    func testSkillJunkIsIgnoredAndBinaryAssetsAreVersioned() throws {
        let fixture = try Fixture()
        try fixture.write(".claude/skills/review/SKILL.md", "# Review")
        try fixture.writeData(".claude/skills/review/.DS_Store", Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]))
        try fixture.writeData(".claude/skills/review/scripts/__pycache__/check.cpython-313.pyc", Data([0xf3, 0x0d, 0x0d, 0x0a, 0, 0]))
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d])
        try fixture.writeData(".claude/skills/review/assets/icon.png", png)
        let skill = try XCTUnwrap(Scanner().files(in: fixture.source).first)
        let snapshot = try XCTUnwrap(SafeFiles.capture(root: fixture.repo.path, file: skill))
        XCTAssertEqual(Set(snapshot.entries.keys), ["SKILL.md", "assets/icon.png"])
        XCTAssertTrue(snapshot.displayText.contains("(binary file"))
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".claude/skills/review/assets"))
        try SafeFiles.restore(snapshot, root: fixture.repo.path, file: skill)
        XCTAssertEqual(try Data(contentsOf: fixture.repo.appendingPathComponent(".claude/skills/review/assets/icon.png")), png)
    }

    func testBinaryAssetWithEmbeddedPrivateKeyBlocksTheSkill() throws {
        let fixture = try Fixture()
        try fixture.write(".claude/skills/review/SKILL.md", "# Review")
        try fixture.writeData(".claude/skills/review/blob.bin", Data([0, 1, 2]) + Data("-----BEGIN RSA PRIVATE KEY-----".utf8))
        let skill = try XCTUnwrap(Scanner().files(in: fixture.source).first)
        XCTAssertThrowsError(try SafeFiles.capture(root: fixture.repo.path, file: skill)) { XCTAssertEqual($0 as? HarnessError, .blocked("blob.bin")) }
    }

    func testSkillRestoreCannotEscapeAndPreservesNewFiles() throws {
        let fixture = try Fixture()
        try fixture.write(".agents/skills/review/SKILL.md", "current")
        try fixture.write(".agents/skills/review/new.md", "preserve")
        let skill = TrackedFile(sourceID: fixture.source.id, path: ".agents/skills/review", category: "skills", tool: "shared", isDirectory: true)
        XCTAssertThrowsError(try SafeFiles.restore(Snapshot(entries: ["../escape": Data()]), root: fixture.repo.path, file: skill))
        try SafeFiles.restore(Snapshot(entries: ["SKILL.md": Data("old".utf8), "refs/guide.md": Data("guide".utf8)]), root: fixture.repo.path, file: skill)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent(".agents/skills/review/SKILL.md"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent(".agents/skills/review/new.md"), encoding: .utf8), "preserve")
    }

    func testExecutableSkillScriptsRetainOwnerExecutionOnRestore() throws {
        let fixture = try Fixture()
        try fixture.write(".agents/skills/check/SKILL.md", "# Check")
        try fixture.write(".agents/skills/check/check.sh", "echo checked")
        let script = fixture.repo.appendingPathComponent(".agents/skills/check/check.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let skill = TrackedFile(sourceID: fixture.source.id, path: ".agents/skills/check", category: "skills", tool: "shared", isDirectory: true)
        let snapshot = try XCTUnwrap(SafeFiles.capture(root: fixture.repo.path, file: skill))
        XCTAssertEqual(snapshot.executablePaths, ["check.sh"])
        try FileManager.default.removeItem(at: script)
        try SafeFiles.restore(snapshot, root: fixture.repo.path, file: skill)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)
        XCTAssertNotEqual(mode.intValue & 0o100, 0)
    }
}
