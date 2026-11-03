import Foundation
import Darwin

public struct WatchReport: Sendable, Equatable {
    public var watched = 0
    public var skipped = 0
    public var failed: [String] = []
    public init() {}
    public var warning: String? {
        var parts: [String] = []
        if skipped > 0 { parts.append("\(skipped) paths exceed the watch budget; periodic discovery covers them.") }
        if !failed.isEmpty { parts.append("Could not watch \(failed.count) paths; periodic discovery covers them. First: \(failed[0])") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// One descriptor per watched path, bounded by a budget below the process limit. Updates keep the
/// sources of unchanged paths and replace those whose inode changed, such as after an atomic save.
/// Callers serialize `watch` and `stop`; the Engine actor does.
public final class FileWatcher: @unchecked Sendable {
    private struct Watch { let source: DispatchSourceFileSystemObject; let device: dev_t; let inode: ino_t }
    private let lock = NSLock()
    private var watches: [String: Watch] = [:]
    private var fileIDs: [String: Set<String>] = [:]
    private var handler: (@Sendable (Set<String>) -> Void)?
    private let queue = DispatchQueue(label: "md.harnessmd.watchers", qos: .utility)
    public let budget: Int

    public init(budget: Int = FileWatcher.defaultBudget()) { self.budget = budget }
    deinit { stop() }

    /// Leaves headroom for SQLite, file reads, and CLI processes.
    public static func defaultBudget() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 128 }
        let soft = Int(clamping: limit.rlim_cur)
        return max(0, min(8192, soft - max(128, soft / 4)))
    }

    public func stop() {
        lock.lock(); let old = watches; watches = [:]; fileIDs = [:]; handler = nil; lock.unlock()
        for watch in old.values { watch.source.cancel() }
    }

    @discardableResult
    public func watch(inventory: Inventory, onChange: @escaping @Sendable (Set<String>) -> Void) -> WatchReport {
        // Files catch in-place writes, parents catch atomic replacements, skill entries come last.
        var wanted: [String: (priority: Int, ids: Set<String>)] = [:]
        func add(_ path: String, _ priority: Int, _ id: String) {
            var entry = wanted[path] ?? (priority, [])
            entry.priority = min(entry.priority, priority); entry.ids.insert(id)
            wanted[path] = entry
        }
        var report = WatchReport()
        let sources = Dictionary(inventory.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for file in inventory.files {
            guard let source = sources[file.sourceID], source.enabled else { continue }
            let url = URL(fileURLWithPath: source.root).appendingPathComponent(file.path)
            add(url.path, 0, file.id)
            add(url.deletingLastPathComponent().path, 1, file.id)
            guard file.isDirectory, let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { failed, _ in
                report.failed.append(failed.path); return true
            }) else { continue }
            for case let child as URL in iterator {
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != false { iterator.skipDescendants(); continue }
                add(child.path, 2, file.id)
            }
        }
        let selected = wanted.sorted { ($0.value.priority, $0.key) < ($1.value.priority, $1.key) }.prefix(budget)
        report.skipped = wanted.count - selected.count

        lock.lock()
        var previous = watches
        handler = onChange
        fileIDs = Dictionary(uniqueKeysWithValues: selected.map { ($0.key, $0.value.ids) })
        lock.unlock()
        var next: [String: Watch] = [:]
        for (path, _) in selected {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno != ENOENT { report.failed.append(path) }
                continue
            }
            if let existing = previous[path], existing.device == info.st_dev, existing.inode == info.st_ino {
                next[path] = existing; previous[path] = nil; continue
            }
            guard info.st_mode & S_IFMT != S_IFLNK, physicalURL(URL(fileURLWithPath: path)).path == path else { continue }
            let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if errno != ENOENT { report.failed.append(path) }
                continue
            }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { report.failed.append(path); close(fd); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .extend], queue: queue)
            source.setEventHandler { [weak self] in self?.notify(path) }
            source.setCancelHandler { close(fd) }
            source.resume()
            next[path] = Watch(source: source, device: opened.st_dev, inode: opened.st_ino)
        }
        lock.lock(); watches = next; lock.unlock()
        // Replaced inodes and paths no longer wanted.
        for watch in previous.values { watch.source.cancel() }
        report.watched = next.count
        return report
    }

    private func notify(_ path: String) {
        lock.lock(); let ids = fileIDs[path], handler = handler; lock.unlock()
        if let ids, let handler { handler(ids) }
    }
}
