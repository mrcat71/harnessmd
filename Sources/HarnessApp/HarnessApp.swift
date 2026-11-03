import SwiftUI
import AppKit
import HarnessKit

@main
enum HarnessMain {
    @MainActor static func main() async {
        // Before any watcher budget is computed: launchd starts apps at a 256 descriptor soft limit.
        raiseOpenFileLimit()
        if CommandLine.arguments.contains("--validate-update-configuration") {
            if let problem = UpdateConfiguration.problem(for: .main) {
                fputs("Update configuration: \(problem)\n", stderr); exit(1)
            }
            print("harnessmd update configuration passed"); exit(0)
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try await SmokeTest.run(); print("harnessmd self-test passed"); exit(0) }
            catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        HarnessApp.main()
    }
}

struct HarnessApp: App {
    @NSApplicationDelegateAdaptor(HarnessApplicationDelegate.self) private var delegate
    @State private var state = AppState()
    var body: some Scene {
        MenuBarExtra("harnessmd", systemImage: "square.stack.3d.up") {
            Text("harnessmd").font(.headline)
            Text("\(state.activeSources.count) sources · \(state.liveFiles.count) files · \(state.changesToday) changes today")
            Divider()
            Button("Open Dashboard") { state.openDashboard() }.keyboardShortcut("o")
            Button(state.scanning ? "Scanning..." : "Scan Now") { Task { await state.scan() } }.disabled(state.scanning)
            Button(state.settings.paused ? "Resume Watching" : "Pause Watching") { state.togglePause() }
            Menu("Recent Changes") {
                if state.inventory.changes.isEmpty { Text("No changes yet") }
                ForEach(Array(state.inventory.changes.prefix(5))) { version in
                    Button(state.fileName(version.fileID)) {
                        state.selection = [version.fileID]; state.openDashboard(page: "library")
                    }
                }
            }
            Divider()
            Button(state.analyzing ? "AI Analysis Running..." : "Run AI Analysis...") {
                state.openDashboard(page: "library"); state.prepareAnalysis()
            }.disabled(state.analyzing || state.liveFiles.isEmpty)
            Button("Settings...") { state.openDashboard(page: "settings") }.keyboardShortcut(",")
            CheckForUpdatesCommand()
            Divider()
            Button("Quit harnessmd") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor
final class HarnessApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--demo"), CommandLine.arguments.contains("--preview-update") {
            Task { @MainActor in
                let offer = UpdateOffer(version: "0.2.0", currentVersion: "0.1.0", size: 7_637_599,
                                        notes: "### Added\n- Signed updates from GitHub Releases\n- An animated update notice")
                let phases: [UpdatePhase] = [.available(offer), .downloading(offer, received: 3_818_799, expected: 7_637_599),
                                             .preparing(offer, progress: 0.65), .ready(offer)]
                for phase in phases {
                    UpdateCardCenter.shared.show(UpdateNotice.make(phase, handlers: .init()))
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
        #endif
        guard !CommandLine.arguments.contains("--demo") else { return }
        AppUpdater.shared.start()
    }
}

enum SmokeTest {
    static func run() async throws {
        let root = physicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("harnessmd-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repos/demo/.git"), withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { NSLog("harnessmd: Smoke fixture cleanup failed: %@", error.localizedDescription) }
        }
        let file = root.appendingPathComponent("repos/demo/AGENTS.md")
        try Data("# Original\nRun the tests.\n".utf8).write(to: file)
        let engine = try Engine(directory: root.appendingPathComponent("store"))
        var settings = AppSettings(); settings.roots = [root.appendingPathComponent("repos").path]
        try await engine.save(settings: settings)
        let report = try await engine.scan()
        guard report.files == 1, report.warnings.isEmpty else { throw HarnessError.invalid("Fixture discovery failed.") }
        let first = try await engine.inventory().versions[0]
        try Data("# Modified\nRun more tests.\n".utf8).write(to: file)
        _ = try await engine.scan()
        try await engine.restore(versionID: first.id)
        guard try String(contentsOf: file, encoding: .utf8) == "# Original\nRun the tests.\n" else { throw HarnessError.invalid("Restore failed.") }
        let inventory = try await engine.inventory()
        guard inventory.versions.contains(where: { $0.origin == "pre_restore" }) else { throw HarnessError.invalid("Missing safety snapshot.") }
    }
}
