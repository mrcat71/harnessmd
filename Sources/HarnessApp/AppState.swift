import SwiftUI
import AppKit
import HarnessKit
import ServiceManagement

/// A restore that needs explicit consent because the current content can't be kept as a safety snapshot.
struct PendingOverwrite: Identifiable {
    let version: Version
    let reason: String
    var id: String { version.id }
}

@MainActor @Observable
final class AppState {
    let engine: Engine?
    var inventory = Inventory()
    var findings: [Finding] = []
    var settings = AppSettings()
    var scanning = false
    var analyzing = false
    var mutating = false
    var error: String?
    var scanWarnings: [String] = []
    var captureWarnings: [String] = []
    var analysisWarnings: [String] = []
    var watchWarning: String?
    var warnings: [String] { scanWarnings + captureWarnings + analysisWarnings + (watchWarning.map { [$0] } ?? []) }
    var lastScan: Date?
    var navigation = "overview"
    var selection: Set<String> = []
    var search = ""
    var category = "all"
    /// "all", "tracked" (added to Git), or "untracked" (repository files outside Git).
    var gitFilter = "all"
    /// Review filters: "all", "ai", or "checks"; Git as in `gitFilter`; waiting for a decision or done.
    var reviewKind = "all"
    var reviewGit = "all"
    var reviewDone = false
    var reviewSearch = ""
    /// The selected Review item; a new diff from a single request gets selected.
    var reviewSelection: String?
    /// Selected Review rows (group IDs); Shift, Command, and Command-A select several.
    var reviewRows: Set<String> = []
    var showingRestore = false
    var restoreDate = Date().addingTimeInterval(-86_400)
    var restorePlans: [RestorePlan] = []
    var analysisPreview: AnalysisRequest?
    /// Why the edited instructions can't be sent yet, such as an oversized payload.
    var previewProblem: String?
    /// One request per file: faster replies and results as each file finishes. Off sends all files together.
    var analysisOneByOne = true
    /// Also send files already analyzed with the same instructions and unchanged since.
    var analysisRepeats = false
    var analysisProgress: (done: Int, total: Int, current: String)?
    var analysisStarted: Date?
    var showingPreview = false
    var availableModels: [String] = []
    var loadingModels = false
    var pendingOverwrite: PendingOverwrite?
    var loginStatus = SMAppService.mainApp.status
    var status = "Ready when you are"
    let storeURL: URL
    private var loop: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var pendingWatchIDs: Set<String> = []
    private var pendingSince: Date?
    private var window: NSWindow?
    /// The Review list's frame in window coordinates (top-left origin), where Control-click selects.
    var reviewListFrame: CGRect = .zero
    private var clickMonitor: Any?

    init() {
        let demo = CommandLine.arguments.contains("--demo")
        // `--page library` opens the dashboard on that page, for screenshots and layout checks.
        if let flag = CommandLine.arguments.firstIndex(of: "--page"), flag + 1 < CommandLine.arguments.count {
            let page = CommandLine.arguments[flag + 1]
            navigation = ["analysis", "proposals"].contains(page) ? "review" : page
        }
        if demo {
            storeURL = physicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("harnessmd-demo-" + UUID().uuidString)
        } else {
            storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("harnessmd")
        }
        do { engine = try Engine(directory: storeURL) }
        catch { engine = nil; self.error = error.localizedDescription }
        installControlClickSelection()
        UpdateCardCenter.shared.onPresent = { [weak self] in self?.openDashboard() }
        Task {
            guard let engine else { return }
            do {
                if demo { try await seedDemo(engine: engine) }
                settings = try await engine.settings()
                await refresh()
                if !settings.paused { await scan() }
                startLoop()
                if demo { openDashboard() }
            } catch { self.error = error.localizedDescription }
        }
    }

    var activeSources: [Source] { inventory.sources.filter { $0.enabled && settings.permits($0) } }
    var changesToday: Int { inventory.changesToday }
    var liveFiles: [TrackedFile] { inventory.files.filter { $0.blob != nil } }
    var pendingProposals: [Proposal] { inventory.proposals.filter { $0.status == "pending" } }
    var openFindings: [Finding] { findings.filter { !inventory.dismissed.contains($0.key) } }
    /// Files (rows) with a diff waiting or a check not marked fine.
    var reviewCount: Int { ReviewGroup.grouped(pendingProposals.map(ReviewItem.proposal) + openFindings.map(ReviewItem.finding)).count }
    /// Sources where collection found instruction files; empty folders stay out of the sidebar.
    var sourcesWithFiles: [Source] {
        let live = Set(liveFiles.map(\.sourceID))
        return inventory.sources.filter { live.contains($0.id) }
    }
    var untrackedCount: Int { liveFiles.filter { inventory.gitTracked[$0.id] == false }.count }
    /// Outside Git if any repository file is; in Git if all are. Nil for global files, which have no repository.
    func gitState(_ fileIDs: [String]) -> Bool? {
        let states = fileIDs.compactMap { inventory.gitTracked[$0] }
        return states.contains(false) ? false : states.isEmpty ? nil : true
    }
    /// A diff already waiting for any of these files, such as an earlier suggested fix.
    func waitingProposal(for fileIDs: [String]) -> Proposal? {
        pendingProposals.first { $0.edits.contains { fileIDs.contains($0.fileID) } }
    }
    func filesLabel(_ fileIDs: [String]) -> String {
        guard let first = fileIDs.first else { return "No files" }
        return fileLabel(first) + (fileIDs.count > 1 ? " and \(fileIDs.count - 1) more" : "")
    }
    var reviewGroups: [ReviewGroup] { ReviewGroup.grouped(reviewItems) }
    /// Shows one item: selects its row and its tab.
    func focus(_ itemID: String) {
        reviewSelection = itemID
        if let group = reviewGroups.first(where: { $0.items.contains { $0.id == itemID } }) { reviewRows = [group.id] }
    }
    var reviewItems: [ReviewItem] {
        let proposals = inventory.proposals.filter { ($0.status == "pending") != reviewDone }.map(ReviewItem.proposal)
        let checks = findings.filter { inventory.dismissed.contains($0.key) == reviewDone }
            .sorted { (findingSource($0), $0.title) < (findingSource($1), $1.title) }.map(ReviewItem.finding)
        return ((reviewKind == "checks" ? [] : proposals) + (reviewKind == "ai" ? [] : checks)).filter { item in
            (reviewGit == "all" || gitState(item.fileIDs) == (reviewGit == "tracked"))
                && (reviewSearch.isEmpty || (item.fileIDs.map(fileLabel) + [item.summary]).joined(separator: " ").localizedCaseInsensitiveContains(reviewSearch))
        }
    }
    var filteredFiles: [TrackedFile] {
        inventory.files.filter { file in
            (navigation == "library" || navigation == "overview" || navigation == "recent" || file.sourceID == navigation)
                && (category == "all" || category == file.category)
                && (gitFilter == "all" || inventory.gitTracked[file.id] == (gitFilter == "tracked"))
                && (search.isEmpty || (file.path + " " + sourceName(file.sourceID) + " " + file.tool).localizedCaseInsensitiveContains(search))
        }
    }
    func sourceName(_ id: String) -> String { inventory.sources.first { $0.id == id }.map(sourceLabel) ?? "Source" }
    /// Repositories that share a folder name also show their parent folder, so two `airflow` checkouts stay distinguishable.
    func sourceLabel(_ source: Source) -> String {
        let twins = inventory.sources.filter { $0.name == source.name }
        guard twins.count > 1 else { return source.name }
        func parent(_ twin: Source) -> String { URL(fileURLWithPath: twin.root).deletingLastPathComponent().lastPathComponent }
        let mine = parent(source)
        return twins.filter { parent($0) == mine }.count > 1 ? source.name + " · " + source.root : source.name + " · " + mine
    }
    /// The repository a finding belongs to, for grouping.
    func findingSource(_ finding: Finding) -> String {
        finding.fileIDs.first.flatMap { id in inventory.files.first { $0.id == id } }.map { sourceName($0.sourceID) } ?? "Other"
    }
    var analysisLabel: String {
        guard let progress = analysisProgress else { return "Suggesting edits" }
        return progress.total > 1 ? "Suggesting edits \(progress.done + 1) of \(progress.total): \(progress.current)" : "Suggesting edits: \(progress.current)"
    }
    func fileName(_ id: String) -> String { inventory.files.first { $0.id == id }?.path ?? "File" }
    /// Source and path, as the AI payload names the file.
    func fileLabel(_ id: String) -> String {
        guard let file = inventory.files.first(where: { $0.id == id }) else { return "Removed file" }
        return (inventory.sources.first { $0.id == file.sourceID }?.name ?? "Source") + "/" + file.path
    }
    func versionCount(_ id: String) -> Int { inventory.versionCounts[id] ?? 0 }

    /// A file's full history; the inventory keeps only recent versions.
    func history(_ fileID: String) async -> [Version] {
        guard let engine else { return [] }
        do { return try await engine.versions(fileID: fileID) }
        catch { self.error = error.localizedDescription; return [] }
    }

    /// Control-click in the Review list adds or removes a row, as Command-click does: the list has no context menu, and
    /// hands used to other systems reach for Control. Elsewhere Control-click stays a secondary click.
    private func installControlClickSelection() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            var flags = event.modifierFlags
            guard flags.contains(.control), !flags.contains(.command) else { return event }
            let location = event.locationInWindow, windowNumber = event.windowNumber
            // Event monitors run on the main thread.
            let inReviewList = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.navigation == "review", let window = self.window, window.windowNumber == windowNumber, let content = window.contentView else { return false }
                return self.reviewListFrame.contains(CGPoint(x: location.x, y: content.bounds.height - location.y))
            }
            guard inReviewList else { return event }
            flags.remove(.control); flags.insert(.command)
            return NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: flags, timestamp: event.timestamp, windowNumber: windowNumber,
                                      context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) ?? event
        }
    }

    func openDashboard(page: String? = nil) {
        if let page { navigation = page }
        if window == nil {
            let view = DashboardView(state: self)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "harnessmd"
            window.contentView = NSHostingView(rootView: view)
            window.minSize = NSSize(width: 980, height: 640)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("Dashboard")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refresh() async {
        guard let engine else { return }
        do {
            inventory = try await engine.inventory()
            let report = try await engine.findings()
            findings = report.findings; analysisWarnings = report.warnings
        } catch { self.error = error.localizedDescription }
    }

    func scan() async {
        guard let engine, !scanning, !mutating else { return }
        scanning = true; status = "Looking for instruction changes..."
        defer { scanning = false }
        do {
            let report = try await engine.scan()
            scanWarnings = report.warnings; captureWarnings = []; lastScan = Date()
            status = "\(report.files) files checked across \(report.sources) sources"
            await refresh(); configureWatchers()
        } catch { self.error = error.localizedDescription; status = "Scan needs attention" }
    }

    func saveSettings() async {
        guard let engine else { return }
        do { try await engine.save(settings: settings); configureWatchers() }
        catch { self.error = error.localizedDescription }
    }

    func togglePause() {
        settings.paused.toggle()
        if settings.paused { debounce?.cancel(); debounce = nil; pendingWatchIDs = []; pendingSince = nil }
        Task { await saveSettings(); if !settings.paused { await scan() } }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Choose folders containing Git repositories. harnessmd only collects recognized agent files."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = physicalURL(url).path
            if !settings.roots.contains(path) { settings.roots.append(path) }
        }
        Task { await saveSettings(); await scan() }
    }

    func updateSource(_ source: Source, isPrivate: Bool? = nil, enabled: Bool? = nil) {
        var updated = source
        if let isPrivate { updated.isPrivate = isPrivate }
        if let enabled { updated.enabled = enabled }
        Task {
            do { try await engine?.save(source: updated); await refresh(); configureWatchers() }
            catch { self.error = error.localizedDescription }
        }
    }

    func restore(_ version: Version, overwriteUnstorable: Bool = false) {
        guard !mutating else { return }; mutating = true
        Task {
            defer { mutating = false }
            do { try await engine?.restore(versionID: version.id, overwriteUnstorableCurrent: overwriteUnstorable); await refresh(); configureWatchers() }
            catch HarnessError.unstorableCurrent(let reason) { pendingOverwrite = PendingOverwrite(version: version, reason: reason) }
            catch { self.error = error.localizedDescription }
        }
    }

    func openRestore() {
        guard !selection.isEmpty else { return }
        restorePlans = []; showingRestore = true
        planRestore()
    }

    func planRestore() {
        let ids = selection, date = restoreDate
        Task {
            do { restorePlans = try await engine?.planRestore(fileIDs: ids, asOf: date) ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Each file gets its own safety snapshot; files that can't be snapshotted are reported, not overwritten.
    func runRestore() {
        guard !mutating, let engine else { return }
        let plans = restorePlans
        mutating = true
        Task {
            defer { mutating = false }
            let report = await engine.restore(plans)
            showingRestore = false
            status = "Restored \(report.restored.count) files" + (report.skipped.isEmpty ? "" : ", skipped \(report.skipped.count)")
            if !report.skipped.isEmpty { self.error = "Not restored:\n" + report.skipped.joined(separator: "\n") + "\nRestore these one at a time from their history." }
            await refresh(); configureWatchers()
        }
    }

    /// `instructions` replaces the default task; `together` sends the files in one request, for problems between files;
    /// `again` also sends files already analyzed with these instructions.
    func prepareAnalysis(ids: Set<String>? = nil, instructions: String? = nil, together: Bool = false, again: Bool = false) {
        guard !analyzing else { return }
        Task {
            do {
                var request = try await engine?.prepareAnalysis(fileIDs: ids ?? (selection.isEmpty ? Set(filteredFiles.map(\.id)) : selection))
                if let instructions { request = try request?.with(instructions: instructions) }
                analysisPreview = request
                analysisOneByOne = !together; analysisRepeats = again
                previewProblem = analysisPreview?.sizeProblem(oneByOne: analysisOneByOne)
                showingPreview = analysisPreview != nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Rebuilds the exact payload for edited instructions, so the preview always shows what will be sent.
    func updatePreview(instructions: String, oneByOne: Bool, thorough: Bool) {
        guard let request = analysisPreview else { return }
        analysisOneByOne = oneByOne
        do {
            var updated = try request.with(instructions: instructions)
            updated.thorough = thorough
            analysisPreview = updated; previewProblem = updated.sizeProblem(oneByOne: oneByOne)
        } catch { previewProblem = error.localizedDescription }
    }

    /// Switches backend, remembering the previous one's path, model, and effort.
    func selectBackend(_ backend: String) {
        guard backend != settings.backend, let next = Backend(rawValue: backend) else { return }
        settings.backendChoices[settings.backend] = BackendChoice(binary: settings.binary, model: settings.model, effort: settings.effort)
        let choice = settings.backendChoices[backend] ?? BackendChoice(binary: next.defaultBinary(), model: "", effort: "")
        settings.backend = backend; settings.binary = choice.binary; settings.model = choice.model; settings.effort = choice.effort
        availableModels = []
        refreshModels()
    }

    func refreshModels() {
        let current = settings
        loadingModels = true
        Task {
            defer { loadingModels = false }
            do {
                let models = try await AIService.models(for: current)
                if current.backend == settings.backend { availableModels = models }
            } catch { availableModels = []; self.error = "Model list: " + error.localizedDescription }
        }
    }

    /// What the preview will send: without files already analyzed with these instructions, unless asked.
    var outgoingAnalysis: AnalysisRequest? {
        guard let request = analysisPreview else { return nil }
        guard !analysisRepeats, !request.repeats.isEmpty else { return request }
        do { return try request.without(Set(request.repeats)) } catch { return request }
    }

    func runAnalysis() {
        guard let request = outgoingAnalysis, !request.inputs.isEmpty, previewProblem == nil, let engine, !analyzing else { return }
        let requests: [AnalysisRequest]
        do { requests = analysisOneByOne && request.inputs.count > 1 ? try request.perFile() : [request] }
        catch { self.error = error.localizedDescription; return }
        showingPreview = false; analyzing = true; analysisStarted = Date()
        aiTask = Task {
            defer { analyzing = false; analysisPreview = nil; analysisProgress = nil; analysisStarted = nil }
            var failures: [String] = [], diffs = 0, unchanged = 0, last: (name: String, proposal: Proposal)?
            for (index, single) in requests.enumerated() {
                guard !Task.isCancelled else { break }
                let name = single.inputs.count == 1 ? single.inputs[0].path : "\(single.inputs.count) files"
                analysisProgress = (index, requests.count, name)
                do {
                    let proposal = try await engine.analyze(single)
                    if proposal.edits.isEmpty { unchanged += 1 } else { diffs += 1 }
                    last = (name, proposal)
                    // Each file's result shows up as soon as it is ready.
                    await refresh()
                } catch {
                    if Task.isCancelled { break }
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }
            await refresh()
            if diffs > 0 { navigation = "review"; reviewDone = false }
            // One request asked for one answer: show its diff, or say why there is none.
            if requests.count == 1, let last {
                if last.proposal.edits.isEmpty {
                    let said = last.proposal.rationale.isEmpty ? "" : "\n\nThe model said: " + last.proposal.rationale
                    self.error = "No changes proposed for \(last.name)." + said + "\n\nTry Thorough in the preview for a deeper look."
                } else { focus("proposal|" + last.proposal.id) }
            }
            // Files that need nothing are only counted here; the inbox holds diffs.
            status = "Suggested edits: \(diffs) with changes" + (unchanged > 0 ? ", \(unchanged) need none" : "") + (failures.isEmpty ? "" : ", \(failures.count) failed")
            if Task.isCancelled { status = "Stopped suggesting edits after \(diffs + unchanged) of \(requests.count)" }
            if !failures.isEmpty { self.error = "Suggesting edits failed for \(failures.count) of \(requests.count):\n" + failures.joined(separator: "\n") }
        }
    }
    func cancelAnalysis() { aiTask?.cancel() }

    /// Sends a local check's files to the model with the check as the task; the fix comes back as a diff in Review.
    func fix(_ finding: Finding, again: Bool = false) {
        guard let engine else { return }
        Task {
            do { prepareAnalysis(ids: Set(finding.fileIDs), instructions: try await engine.fixInstructions(for: finding), together: finding.fileIDs.count > 1, again: again) }
            catch { self.error = error.localizedDescription }
        }
    }

    func keep(_ proposal: Proposal) { decideInReview { try await $0.keep(proposalID: proposal.id) } }
    func reopen(_ proposal: Proposal) { decideInReview { try await $0.reopen(proposalID: proposal.id) } }
    func setFine(_ finding: Finding, _ fine: Bool) { decideInReview { try await $0.setDismissed(findingKey: finding.key, fine) } }
    func decide(_ proposal: Proposal, accept: Bool) {
        decideInReview { engine in
            if accept { try await engine.accept(proposalID: proposal.id) } else { try await engine.reject(proposalID: proposal.id) }
        }
    }

    enum BulkDecision { case fine, reject, accept, putBack }

    /// One decision for every item of the selected rows. Each item is tried; the ones that fail are listed together.
    func decideAll(_ groups: [ReviewGroup], _ decision: BulkDecision) {
        let items = groups.flatMap(\.items), dismissed = inventory.dismissed
        decideInReview { engine in
            var failures: [String] = []
            for item in items {
                do {
                    switch (item, decision) {
                    case (.proposal(let proposal), .fine) where proposal.status == "pending": try await engine.keep(proposalID: proposal.id)
                    case (.proposal(let proposal), .reject) where proposal.status == "pending": try await engine.reject(proposalID: proposal.id)
                    case (.proposal(let proposal), .accept) where proposal.status == "pending": try await engine.accept(proposalID: proposal.id)
                    case (.proposal(let proposal), .putBack) where proposal.status == "kept": try await engine.reopen(proposalID: proposal.id)
                    case (.finding(let finding), .fine) where !dismissed.contains(finding.key): try await engine.setDismissed(findingKey: finding.key, true)
                    case (.finding(let finding), .putBack) where dismissed.contains(finding.key): try await engine.setDismissed(findingKey: finding.key, false)
                    default: break
                    }
                } catch { failures.append(self.fileLabel(item.fileIDs.first ?? "") + ": " + error.localizedDescription) }
            }
            if !failures.isEmpty { throw HarnessError.invalid("Not done for \(failures.count):\n" + failures.joined(separator: "\n")) }
        }
    }

    /// Runs a Review decision, then moves on like Mail: the same row while it has items left, else the next row.
    private func decideInReview(_ work: @escaping (Engine) async throws -> Void) {
        let before = reviewGroups
        // With nothing selected the first row is shown, so that is the one being decided.
        let selected = Set(before.indices.filter { reviewRows.contains(before[$0].id) }).union(reviewRows.isEmpty && !before.isEmpty ? [0] : [])
        perform(work) { [self] in
            configureWatchers()
            let after = reviewGroups
            let next = rowAfterDecision(before: before.map { $0.items.map(\.id) }, selected: selected, after: after.map { $0.items.map(\.id) })
            if !(selected.count == 1 && next.map({ after[$0].items.contains { $0.id == reviewSelection } }) == true) { reviewSelection = nil }
            reviewRows = next.map { [after[$0].id] } ?? []
        }
    }

    private func perform(_ work: @escaping (Engine) async throws -> Void, then: (() -> Void)? = nil) {
        guard !mutating, let engine else { return }
        mutating = true
        Task {
            defer { mutating = false }
            do { try await work(engine) } catch { self.error = error.localizedDescription }
            await refresh()
            then?()
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Login item: " + error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }
    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                if !self.settings.paused && Date().timeIntervalSince(self.lastScan ?? .distantPast) >= max(30, self.settings.sweepSeconds) { await self.scan() }
            }
        }
    }
    private func configureWatchers() {
        var watched = inventory
        watched.sources = inventory.sources.filter { settings.permits($0) }
        let paused = settings.paused
        Task { [self] in
            guard let engine else { return }
            let report = await engine.configureWatching(inventory: watched, paused: paused) { [weak self] ids in
                Task { @MainActor [weak self] in self?.scheduleCapture(ids) }
            }
            watchWarning = report.warning
        }
    }
    /// Debounces bursts, but never holds a change more than three seconds behind its first event.
    private func scheduleCapture(_ ids: Set<String>) {
        guard !settings.paused else { return }
        pendingWatchIDs.formUnion(ids)
        let now = Date(), since = pendingSince ?? now
        pendingSince = since
        let delay = min(0.5, since.addingTimeInterval(3).timeIntervalSince(now))
        if delay <= 0, debounce != nil { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
            guard let self, !self.settings.paused else { return }
            let ids = self.pendingWatchIDs
            self.pendingWatchIDs = []; self.pendingSince = nil; self.debounce = nil
            do {
                let warnings = try await self.engine?.captureWatched(fileIDs: ids) ?? []
                self.captureWarnings += warnings.filter { !self.captureWarnings.contains($0) }
                await self.refresh(); self.configureWatchers()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func seedDemo(engine: Engine) async throws {
        let root = storeURL.appendingPathComponent("fixtures")
        for repo in ["atlas", "notebook", "platform"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(repo + "/.git"), withIntermediateDirectories: true)
            let text = "# \(repo.capitalized)\n\nUse small, focused changes. Run tests before handing off work.\n\n## Verification\nRun `swift test` and review the diff. Keep credentials out of source control.\n"
            try Data(text.utf8).write(to: root.appendingPathComponent(repo + "/AGENTS.md"))
        }
        let skill = root.appendingPathComponent("atlas/.claude/skills/review")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# Review\nInspect the diff, test behavior, and report evidence.\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("# Claude\nUse project conventions. Build with `scripts/check.sh`.\n".utf8).write(to: root.appendingPathComponent("atlas/CLAUDE.md"))
        var settings = AppSettings(); settings.roots = [root.path]
        try await engine.save(settings: settings); _ = try await engine.scan()
        let atlas = "# Atlas\n\nUse small, focused changes. Run tests before handing off work.\n\n## Verification\nRun `swift test --parallel` and review the diff. Keep credentials out of source control.\n"
        try Data(atlas.utf8).write(to: root.appendingPathComponent("atlas/AGENTS.md"))
        _ = try await engine.scan()
        // A proposal for the inbox, without calling a model.
        let inventory = try await engine.inventory()
        let atlasID = inventory.sources.first { $0.name == "atlas" }?.id
        guard let file = inventory.files.first(where: { $0.sourceID == atlasID && $0.path == "AGENTS.md" }), let blob = file.blob else { return }
        let store = await engine.store
        let changed = TextPatch.apply([
            TextPatch.Change(find: "Use small, focused changes. Run tests before handing off work.\n", replace: "Use small, focused changes. Run `swift test --parallel` before handing off work.\n",
                             why: "Name the exact test command, as Verification does."),
            TextPatch.Change(find: "", replace: "\n## Ownership\nAsk the platform team before changing CI.\n", why: "Say who approves CI changes."),
        ], to: atlas)
        try store.save(Proposal(model: "demo/fixture", rationale: "Names the test command and says who owns CI.", edits: [ProposalEdit(fileID: file.id, baseBlob: blob, content: changed.text, notes: changed.notes)],
                                note: "Demo proposal; nothing was sent to a model.", fileIDs: [file.id]))
    }
}
