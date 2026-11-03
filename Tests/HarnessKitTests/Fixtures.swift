import Foundation
@testable import HarnessKit

final class Fixture {
    let root: URL
    var repo: URL { root.appendingPathComponent("repos/project") }
    init() throws {
        root = physicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("harnessmd-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    deinit {
        do { try FileManager.default.removeItem(at: root) }
        catch { NSLog("Fixture cleanup failed: %@", error.localizedDescription) }
    }
    func write(_ path: String, _ text: String) throws { try writeData(path, Data(text.utf8)) }
    func writeData(_ path: String, _ data: Data) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func link(_ path: String, to target: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }
    func store() throws -> Store { try Store(directory: root.appendingPathComponent("store")) }
    func engine() async throws -> Engine {
        let engine = try Engine(directory: root.appendingPathComponent("store"))
        var settings = AppSettings(); settings.roots = [root.appendingPathComponent("repos").path]
        try await engine.save(settings: settings)
        return engine
    }
    var source: Source { Source(root: repo.path) }
    var file: TrackedFile { TrackedFile(sourceID: source.id, path: "AGENTS.md", category: "instructions", tool: "codex") }
}
