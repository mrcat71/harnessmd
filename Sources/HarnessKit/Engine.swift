import Foundation

public struct AnalysisReport: Sendable {
    public var findings: [Finding] = []
    public var warnings: [String] = []
}

/// What restoring one file to a point in time would do.
public struct RestorePlan: Identifiable, Sendable {
    public enum Action: Sendable, Equatable {
        /// Write the target version back.
        case restore
        /// The file already has that content.
        case unchanged
        /// No version exists that early.
        case untracked
        /// The file did not exist then; it is left as is, never deleted.
        case absent
    }
    public var file: TrackedFile
    public var sourceName: String
    public var target: Version?
    public var action: Action
    public var id: String { file.id }
}

public struct RestoreReport: Sendable {
    public var restored: [String] = []
    public var skipped: [String] = []
}

public actor Engine {
    public let store: Store
    private let watcher: FileWatcher
    /// Findings depend on instruction and skill contents; recomputed only when those change or a scan runs.
    private var analysisCache: (key: [String], report: AnalysisReport)?
    /// Each repository's Git index, reread only when the index file changes.
    private var gitIndexes: [String: (modified: Date, index: GitIndex?)] = [:]

    public init(directory: URL, watchBudget: Int = FileWatcher.defaultBudget()) throws {
        store = try Store(directory: directory)
        watcher = FileWatcher(budget: watchBudget)
    }
    public func inventory() throws -> Inventory {
        var inventory = try store.inventory()
        let files = Dictionary(grouping: inventory.files, by: \.sourceID)
        for source in inventory.sources where !source.isGlobal {
            guard let index = gitIndex(for: source) else { continue }
            for file in files[source.id] ?? [] {
                // A skill counts as added when its SKILL.md is.
                inventory.gitTracked[file.id] = index.contains(file.isDirectory ? file.path + "/SKILL.md" : file.path)
            }
        }
        return inventory
    }

    private func gitIndex(for source: Source) -> GitIndex? {
        guard let url = GitIndex.file(workingTree: URL(fileURLWithPath: source.root)) else { return nil }
        // A repository with nothing added yet has no index file.
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return GitIndex(paths: [], directories: []) }
        let modified = values.contentModificationDate ?? .distantPast
        if let cached = gitIndexes[source.id], cached.modified == modified { return cached.index }
        var index: GitIndex?
        if (values.fileSize ?? 0) <= 64 << 20 {
            do { index = GitIndex.parse(try Data(contentsOf: url)) }
            catch { NSLog("harnessmd: Could not read the Git index of %@: %@", source.name, error.localizedDescription) }
        }
        gitIndexes[source.id] = (modified, index)
        return index
    }

    /// What restoring the files as they were at `date` would do, file by file.
    public func planRestore(fileIDs: Set<String>, asOf date: Date) throws -> [RestorePlan] {
        let inventory = try store.inventory()
        return try inventory.files.filter { fileIDs.contains($0.id) }.map { file in
            let source = inventory.sources.first { $0.id == file.sourceID }
            let target = try store.versions(fileID: file.id).first { $0.capturedAt <= date }
            // Compare with the disk, not the last capture: refused or paused changes are never recorded.
            var current: String?
            if let source {
                do { current = try SafeFiles.capture(root: source.root, file: file)?.identity() }
                catch { current = "unreadable: \(error.localizedDescription)" }
            }
            let action: RestorePlan.Action = target == nil ? .untracked : target?.blob == nil ? .absent : target?.blob == current ? .unchanged : .restore
            return RestorePlan(file: file, sourceName: source?.name ?? "Source", target: target, action: action)
        }
    }

    /// Restores each planned file with its own safety snapshot; one failure does not stop the rest.
    public func restore(_ plans: [RestorePlan]) -> RestoreReport {
        var report = RestoreReport()
        for plan in plans where plan.action == .restore {
            guard let target = plan.target else { continue }
            let label = plan.sourceName + "/" + plan.file.path
            do { try restore(versionID: target.id); report.restored.append(label) }
            catch { report.skipped.append("\(label): \(error.localizedDescription)") }
        }
        return report
    }
    public func versions(fileID: String) throws -> [Version] { try store.versions(fileID: fileID) }
    public func settings() throws -> AppSettings { try store.settings() }
    public func save(settings: AppSettings) throws { try store.save(settings) }
    public func save(source: Source) throws { try store.save(source) }
    public func snapshot(blob: String) throws -> Snapshot { try store.snapshot(blob: blob) }
    public func configureWatching(inventory: Inventory, paused: Bool, onChange: @escaping @Sendable (Set<String>) -> Void) -> WatchReport {
        if paused { watcher.stop(); return WatchReport() }
        return watcher.watch(inventory: inventory, onChange: onChange)
    }

    public func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, origin: String = "scan") throws -> ScanReport {
        defer { analysisCache = nil }
        let settings = try store.settings(), scanner = Scanner(customPatterns: settings.customPatterns)
        let previous = try store.inventory()
        var report = ScanReport()
        var discovered: [Source] = []
        // Failure in one root must not prevent healthy roots from being collected.
        for root in settings.roots {
            do {
                let discovery = try scanner.discover(roots: [root], globals: false, home: home)
                discovered += discovery.sources; report.warnings += discovery.warnings
            } catch { report.warnings.append(error.localizedDescription) }
        }
        if settings.includeGlobals { discovered += try scanner.discover(roots: [], globals: true, home: home).sources }
        let sources = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.root < $1.root }
        var skillDirectories = Set<String>(), linked: [(source: String, target: String)] = []
        for var source in sources {
            if let existing = previous.sources.first(where: { $0.id == source.id }) {
                source.isPrivate = existing.isPrivate; source.enabled = existing.enabled
            }
            guard source.enabled else { continue }
            do {
                // A failed enumeration never records deletions.
                let listing = try scanner.listing(of: source)
                report.warnings += listing.warnings.map { "\(source.name): \($0)" }
                linked += listing.linkedSkills.map { (source.name, $0) }
                try store.save(source)
                for file in listing.files {
                    if file.isDirectory { skillDirectories.insert(source.root + "/" + file.path) }
                    do {
                        let snapshot = try SafeFiles.capture(root: source.root, file: file)
                        try store.capture(file, snapshot: snapshot, origin: origin)
                        report.files += 1
                    } catch { report.warnings.append("\(source.name)/\(file.path): \(error.localizedDescription)") }
                }
                let paths = Set(listing.files.map(\.path))
                for missing in previous.files where missing.sourceID == source.id && !paths.contains(missing.path) && missing.blob != nil {
                    // Recheck known units: removing SKILL.md must not hide changes to its remaining bundle.
                    guard scanner.stillCollected(missing, in: source) else { continue }
                    do { try store.capture(missing, snapshot: SafeFiles.capture(root: source.root, file: missing), origin: origin) }
                    catch { report.warnings.append("\(source.name)/\(missing.path): \(error.localizedDescription)") }
                }
                source.lastScan = Date(); try store.save(source); report.sources += 1
            } catch { report.warnings.append("\(source.name): \(error.localizedDescription)") }
        }
        // Linked skills are versioned only where they live; warn when that place is not collected.
        let uncollected = linked.filter { !skillDirectories.contains($0.target) }
        for (name, links) in Dictionary(grouping: uncollected, by: { $0.source }).sorted(by: { $0.key < $1.key }) {
            let subject = links.count == 1 ? "1 skill links SKILL.md outside collected locations and is" : "\(links.count) skills link SKILL.md outside collected locations and are"
            report.warnings.append("\(name): \(subject) not versioned. First: \(links[0].target)")
        }
        return report
    }

    /// Watcher pass scans only known sources; periodic discovery is separate. Returns per-file warnings.
    public func captureWatched(fileIDs: Set<String>) throws -> [String] {
        let inventory = try store.inventory(), settings = try store.settings()
        var warnings: [String] = []
        for file in inventory.files where fileIDs.contains(file.id) {
            guard let source = inventory.sources.first(where: { $0.id == file.sourceID }), source.enabled, settings.permits(source) else { continue }
            do { try store.capture(file, snapshot: SafeFiles.capture(root: source.root, file: file), origin: "watcher") }
            catch { warnings.append("\(source.name)/\(file.path): \(error.localizedDescription)") }
        }
        return warnings
    }

    public func findings() throws -> AnalysisReport {
        let inventory = try store.inventory()
        let relevant = inventory.files.filter { $0.blob != nil && ($0.category == "instructions" || $0.isDirectory) }
        let key = (relevant.map { "\($0.id):\($0.blob!)" } + inventory.sources.map { "\($0.id):\($0.family)" }).sorted()
        if let analysisCache, analysisCache.key == key { return analysisCache.report }
        var snapshots: [String: Snapshot] = [:], report = AnalysisReport()
        for file in relevant {
            // One unreadable snapshot must not hide every other finding.
            do { snapshots[file.id] = try store.snapshot(blob: file.blob!, entries: file.isDirectory ? ["SKILL.md"] : nil) }
            catch { report.warnings.append("\(inventory.sources.first { $0.id == file.sourceID }?.name ?? "Source")/\(file.path): \(error.localizedDescription)") }
        }
        report.findings = Analyzer.analyze(inventory, snapshots: snapshots)
        analysisCache = (key, report)
        return report
    }

    /// Restores a content version after snapshotting the current state. When the current content
    /// can't be stored (credential-like, binary, or too large), the caller must confirm overwriting it.
    public func restore(versionID: String, overwriteUnstorableCurrent: Bool = false) throws {
        let inventory = try store.inventory()
        guard let version = try store.version(id: versionID), let blob = version.blob,
              let file = inventory.files.first(where: { $0.id == version.fileID }),
              let source = inventory.sources.first(where: { $0.id == file.sourceID }) else { throw HarnessError.invalid("Select a content version, not a deletion.") }
        let snapshot = try store.snapshot(blob: blob)
        var note = "Restored version from \(version.capturedAt.formatted())"
        do {
            let current = try SafeFiles.capture(root: source.root, file: file)
            try store.capture(file, snapshot: current, origin: "pre_restore", force: true, note: "Safety snapshot before restore")
        } catch let error as HarnessError {
            switch error {
            case .blocked, .sensitive, .invalid:
                guard overwriteUnstorableCurrent else { throw HarnessError.unstorableCurrent(error.localizedDescription) }
                note += ". The overwritten content was not stored: \(error.localizedDescription)"
            default: throw error
            }
        }
        try SafeFiles.restore(snapshot, root: source.root, file: file)
        try store.capture(file, snapshot: SafeFiles.capture(root: source.root, file: file), origin: "restore", force: true, note: note)
    }

    public func prepareAnalysis(fileIDs: Set<String>) throws -> AnalysisRequest {
        let inventory = try store.inventory()
        var snapshots: [String: Snapshot] = [:]
        for file in inventory.files where fileIDs.contains(file.id) && file.allowsAI {
            guard let blob = file.blob else { continue }
            // Unreadable snapshots are reported as exclusions by the request builder.
            do { snapshots[file.id] = try store.snapshot(blob: blob, entries: [file.isDirectory ? "SKILL.md" : ""]) }
            catch { NSLog("harnessmd: Excluding %@ from analysis: %@", file.path, error.localizedDescription) }
        }
        var request = try AIService.prepare(inventory: inventory, snapshots: snapshots, fileIDs: fileIDs, settings: store.settings(), kept: store.keptNotes(fileIDs: fileIDs))
        request.history = try store.analyzedTasks(of: request.inputs.map { ($0.fileID, $0.baseBlob) })
        return request
    }

    /// "It's fine": rejects the proposal and tells later requests for its files to leave these points as they are.
    public func keep(proposalID: String) throws {
        guard let proposal = try store.inventory().proposals.first(where: { $0.id == proposalID }), proposal.status == "pending" else { throw HarnessError.invalid("Proposal is no longer pending.") }
        let headline = proposal.rationale.split(separator: "\n").first.map(String.init) ?? ""
        // Whole-file edits from before change notes are remembered by the summary.
        let notes = proposal.edits.flatMap { edit in (edit.notes.isEmpty ? [headline] : edit.notes.map(\.text)).filter { !$0.isEmpty }.map { (fileID: edit.fileID, text: $0) } }
        try store.keep(proposal, notes: notes)
    }

    public func reopen(proposalID: String) throws {
        guard let proposal = try store.inventory().proposals.first(where: { $0.id == proposalID }), proposal.status == "kept" else { throw HarnessError.invalid("Only a kept proposal can be reopened.") }
        try store.reopen(proposal)
    }

    public func setDismissed(findingKey: String, _ dismissed: Bool) throws { try store.setDismissed(findingKey, dismissed) }

    /// The task "Fix with AI" sends for a finding: the problem plus what the disk can tell, because a model
    /// answering without extended thinking changes nothing when it has to guess.
    public func fixInstructions(for finding: Finding) throws -> String {
        let inventory = try store.inventory()
        let files = finding.fileIDs.compactMap { id in inventory.files.first { $0.id == id } }
        if finding.kind == "stale", let file = files.first, let source = inventory.sources.first(where: { $0.id == file.sourceID }) {
            let found = Self.files(named: Set(finding.missing.map { URL(fileURLWithPath: $0).lastPathComponent }), under: source.root)
            let lines = finding.missing.map { path in
                let candidates = found[URL(fileURLWithPath: path).lastPathComponent] ?? []
                return "- `\(path)`: " + (candidates.isEmpty ? "no file with that name exists in the repository"
                    : "files with that name in the repository: " + candidates.map { "`\($0)`" }.joined(separator: ", "))
            }
            return "\(file.path) refers to paths that don't exist in its repository:\n" + lines.joined(separator: "\n")
                + "\nChange each reference to the existing file when one clearly matches. Remove a reference only when no file matches and it isn't an example. Change nothing else."
        }
        if finding.id.hasPrefix("drift|"), files.count == 2 {
            return "\(files[0].path) and \(files[1].path) give agents different instructions. Make them agree: where they contradict, keep the more specific or more recent rule in both. Leave guidance that only one of them needs. Change nothing else."
        }
        return "These files should match but differ: \(finding.detail) Make them say the same, keeping the most complete wording. Change nothing else."
    }

    /// Paths relative to `root` of files with these names, up to five each, skipping `.git` and dependency folders.
    static func files(named names: Set<String>, under root: String, limit: Int = 50_000) -> [String: [String]] {
        var found: [String: [String]] = [:]
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard !names.isEmpty, let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return found }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > limit { break }
            let name = url.lastPathComponent
            if Privacy.junkDirectories.contains(name) { walker.skipDescendants(); continue }
            guard names.contains(name), found[name, default: []].count < 5 else { continue }
            found[name, default: []].append(String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1)))
        }
        return found
    }

    @discardableResult
    public func analyze(_ request: AnalysisRequest, runner: any ProcessRunning = CLIProcessRunner(), http: any HTTPTransport = URLSessionTransport()) async throws -> Proposal {
        // Recheck privacy, enablement, and selected blob identities after the preview is confirmed.
        let inventory = try store.inventory()
        for input in request.inputs {
            guard let file = inventory.files.first(where: { $0.id == input.fileID }), file.blob == input.baseBlob, file.allowsAI,
                  let source = inventory.sources.first(where: { $0.id == file.sourceID }), !source.isPrivate, source.enabled, try store.settings().permits(source) else { throw HarnessError.conflict }
        }
        var invocation = AIInvocation(backend: request.settings.backend, model: request.settings.model, fileIDs: request.inputs.map(\.fileID), status: "running")
        try store.save(invocation)
        do {
            let proposal = try await AIService.run(request, runner: runner, http: http)
            // Only a diff needs review, and it replaces an older one waiting for the same file. A file that needs no changes is reported to the caller, not stored.
            if !proposal.edits.isEmpty { try store.saveNewest(proposal) }
            try store.recordAnalysis(of: request.inputs.map { ($0.fileID, $0.baseBlob) }, task: AIService.taskKey(request.instructions))
            invocation.status = "completed"; try store.save(invocation)
            return proposal
        } catch {
            invocation.status = "failed"
            do { try store.save(invocation) } catch { NSLog("harnessmd: Could not persist failed AI invocation: %@", error.localizedDescription) }
            throw error
        }
    }

    public func reject(proposalID: String) throws {
        guard var proposal = try store.inventory().proposals.first(where: { $0.id == proposalID }), proposal.status == "pending" else { throw HarnessError.invalid("Proposal is no longer pending.") }
        proposal.status = "rejected"; try store.save(proposal)
    }

    public func accept(proposalID: String) throws {
        let inventory = try store.inventory()
        guard var proposal = inventory.proposals.first(where: { $0.id == proposalID }), proposal.status == "pending" else { throw HarnessError.invalid("Proposal is no longer pending.") }
        guard Date().timeIntervalSince(proposal.createdAt) <= 30 * 86400 else {
            proposal.status = "expired"; try store.save(proposal); throw HarnessError.invalid("Proposal expired after 30 days.")
        }
        var changes: [(TrackedFile, Source, Snapshot, Snapshot)] = []
        for edit in proposal.edits {
            guard let file = inventory.files.first(where: { $0.id == edit.fileID }), file.allowsAI,
                  let source = inventory.sources.first(where: { $0.id == file.sourceID }), source.enabled,
                  let current = try SafeFiles.capture(root: source.root, file: file), try current.identity() == edit.baseBlob else { throw HarnessError.conflict }
            try Privacy.validate(Data(edit.content.utf8), path: file.path)
            var replacement = current
            replacement.entries[file.isDirectory ? "SKILL.md" : ""] = Data(edit.content.utf8)
            changes.append((file, source, current, replacement))
        }
        // Validate every target and persist every safety snapshot before the first write.
        for (file, _, current, _) in changes { try store.capture(file, snapshot: current, origin: "pre_apply", force: true) }
        var applied: [(TrackedFile, Source, Snapshot)] = []
        do {
            for (file, source, current, replacement) in changes {
                guard try SafeFiles.capture(root: source.root, file: file) == current else { throw HarnessError.conflict }
                try writeProposal(replacement, source: source, file: file)
                applied.append((file, source, current))
                try store.capture(file, snapshot: replacement, origin: "apply", force: true)
            }
        } catch {
            var rollbackFailed = false
            for (file, source, current) in applied.reversed() {
                do {
                    guard let expected = changes.first(where: { $0.0.id == file.id })?.3,
                          try SafeFiles.capture(root: source.root, file: file) == expected else { throw HarnessError.conflict }
                    try writeProposal(current, source: source, file: file)
                    try store.capture(file, snapshot: current, origin: "rollback", force: true)
                } catch { rollbackFailed = true; NSLog("harnessmd: Proposal rollback failed: %@", error.localizedDescription) }
            }
            if rollbackFailed { throw HarnessError.invalid("Apply and rollback failed. Use the pre_apply versions in History to recover.") }
            throw error
        }
        proposal.status = "accepted"; try store.save(proposal)
    }

    private func writeProposal(_ snapshot: Snapshot, source: Source, file: TrackedFile) throws {
        if file.isDirectory {
            guard let data = snapshot.entries["SKILL.md"] else { throw HarnessError.missingBlob }
            try SafeFiles.write(data, root: source.root, path: file.path + "/SKILL.md", executable: snapshot.executablePaths.contains("SKILL.md"))
        } else { try SafeFiles.restore(snapshot, root: source.root, file: file) }
    }
}
