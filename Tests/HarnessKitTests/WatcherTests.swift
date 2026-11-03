import XCTest
@testable import HarnessKit

final class WatcherTests: XCTestCase {
    func testWatcherReportsChangesAndAtomicReplacement() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "first")
        var inventory = Inventory(); inventory.sources = [fixture.source]; inventory.files = [fixture.file]
        let watcher = FileWatcher()
        let changed = expectation(description: "File changed")
        let fileID = fixture.file.id
        changed.assertForOverFulfill = false
        watcher.watch(inventory: inventory) { ids in
            if ids.contains(fileID) { changed.fulfill() }
        }
        try Data("second".utf8).write(to: fixture.repo.appendingPathComponent("AGENTS.md"), options: .atomic)
        await fulfillment(of: [changed], timeout: 3)
        watcher.stop()
    }

    func testBudgetBoundsDescriptors() throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "first")
        var inventory = Inventory(); inventory.sources = [fixture.source]; inventory.files = [fixture.file]
        let watcher = FileWatcher(budget: 1)
        let report = watcher.watch(inventory: inventory) { _ in }
        XCTAssertEqual(report.watched, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertNotNil(report.warning)
        watcher.stop()
    }

    func testRewatchReplacesTheWatchOfAnAtomicallySavedFile() async throws {
        let fixture = try Fixture(); try fixture.write("AGENTS.md", "first")
        var inventory = Inventory(); inventory.sources = [fixture.source]; inventory.files = [fixture.file]
        let watcher = FileWatcher(budget: 16)
        XCTAssertEqual(watcher.watch(inventory: inventory) { _ in }.watched, 2)
        try Data("second".utf8).write(to: fixture.repo.appendingPathComponent("AGENTS.md"), options: .atomic)
        // Let the replacement's events reach the old handler first.
        try await Task.sleep(for: .milliseconds(300))
        let changed = expectation(description: "In-place write after rewatch")
        changed.assertForOverFulfill = false
        let fileID = fixture.file.id
        XCTAssertEqual(watcher.watch(inventory: inventory) { ids in if ids.contains(fileID) { changed.fulfill() } }.watched, 2)
        // An in-place append leaves the directory untouched, so only a refreshed file watch sees it.
        let handle = try FileHandle(forWritingTo: fixture.repo.appendingPathComponent("AGENTS.md"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" more".utf8)); try handle.close()
        await fulfillment(of: [changed], timeout: 3)
        watcher.stop()
    }
}
