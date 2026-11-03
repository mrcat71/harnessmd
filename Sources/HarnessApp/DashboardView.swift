import SwiftUI
import AppKit
import HarnessKit

let accent = Color(red: 0.18, green: 0.58, blue: 0.49)

struct DashboardView: View {
    @Bindable var state: AppState
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                // Pages with little content, like an empty inbox, still fill the column instead of floating centered.
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
                HStack(spacing: 7) {
                    Circle().fill(state.settings.paused ? .orange : accent).frame(width: 6, height: 6)
                    Text(state.settings.paused ? "Watching paused" : state.status)
                    Spacer()
                    if state.analyzing {
                        ProgressView().controlSize(.mini)
                        Text(state.analysisLabel).lineLimit(1).truncationMode(.middle)
                        if let started = state.analysisStarted { Text(started, style: .timer).monospacedDigit() }
                        Button("Stop") { state.cancelAnalysis() }.buttonStyle(.plain)
                    } else {
                        Image(systemName: "externaldrive.badge.checkmark")
                        Text("Local-first · No automatic edits")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .overlay(alignment: .top) { UpdateCardStack() }
        .sheet(isPresented: $state.showingRestore) { BatchRestoreView(state: state) }
        .alert("Needs your attention", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("OK") { state.error = nil }
        } message: { Text(state.error ?? "") }
        .sheet(isPresented: $state.showingPreview) { AIPreviewView(state: state) }
        .confirmationDialog("Overwrite without a safety snapshot?", isPresented: Binding(get: { state.pendingOverwrite != nil }, set: { if !$0 { state.pendingOverwrite = nil } }),
                            titleVisibility: .visible, presenting: state.pendingOverwrite) { pending in
            Button("Overwrite current content", role: .destructive) { state.pendingOverwrite = nil; state.restore(pending.version, overwriteUnstorable: true) }
            Button("Cancel", role: .cancel) { state.pendingOverwrite = nil }
        } message: { pending in
            Text("The current content can't be kept as a safety snapshot (\(pending.reason)). Restoring replaces it, and harnessmd keeps no copy of it.")
        }
    }

    @ViewBuilder private var page: some View {
        switch state.navigation {
        case "overview": OverviewView(state: state)
        case "settings": SettingsView(state: state)
        case "review": ReviewView(state: state)
        case "recent": RecentView(state: state)
        default: LibraryView(state: state)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("harnessmd").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("YOUR AGENT LIBRARY").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                }
            }.padding(20).padding(.top, 8)
            List(selection: $state.navigation) {
                Section("Workspace") {
                    Label("Overview", systemImage: "square.grid.2x2").tag("overview")
                    Label("All files", systemImage: "doc.on.doc").tag("library")
                    Label("Recent changes", systemImage: "clock.arrow.circlepath").tag("recent")
                }
                Section("Intelligence") {
                    Label("Review", systemImage: "checklist").badge(state.reviewCount).tag("review")
                }
                Section("Sources") {
                    ForEach(state.sourcesWithFiles) { source in
                        HStack(spacing: 7) {
                            Image(systemName: source.kind == "repo" ? "folder" : "globe").foregroundStyle(source.enabled ? .secondary : .tertiary)
                            Text(state.sourceLabel(source)).lineLimit(1).truncationMode(.middle).help(source.root)
                            Spacer(minLength: 0)
                            if source.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .tag(source.id)
                        .contextMenu {
                            Button(source.isPrivate ? "Allow AI Analysis" : "Keep Private (Local Only)") { state.updateSource(source, isPrivate: !source.isPrivate) }
                            Button(source.enabled ? "Disable Collection" : "Enable Collection") { state.updateSource(source, enabled: !source.enabled) }
                        }
                    }
                    Button { state.addRoot() } label: { Label("Add a folder...", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Section { Label("Settings", systemImage: "gearshape").tag("settings") }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 8) {
                Label("A little history. A lot of context.", systemImage: "leaf").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text("WATCHING").font(.system(size: 9, weight: .semibold)).tracking(1)
                    Spacer()
                    Text(state.settings.paused ? "Paused" : "Active").font(.system(size: 10, weight: .medium)).foregroundStyle(state.settings.paused ? .orange : accent)
                }
            }.padding(18)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 23, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if state.scanning { ProgressView().controlSize(.small) }
            Button { Task { await state.scan() } } label: { Label("Scan now", systemImage: "arrow.clockwise") }.disabled(state.scanning)
        }.padding(.horizontal, 26).padding(.vertical, 22)
    }
    private var title: String {
        ["overview": "Your agents, in context.", "library": "All files", "recent": "Recent changes", "review": "Review", "settings": "Settings"][state.navigation] ?? state.sourceName(state.navigation)
    }
    private var subtitle: String {
        if state.navigation == "overview" { return "One quiet home for the instructions behind your work." }
        if state.navigation == "review" { return "Edits your AI model suggested and problems found by local checks. Nothing is written until you accept, and every accepted edit gets a safety snapshot." }
        if state.navigation == "settings" { return "Choose what to collect and what stays private." }
        return "Instructions, skills, rules, and configs. Collected locally, versioned automatically."
    }
}

private struct Stat: View {
    var value: String; var label: String; var symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(accent)
            Text(value).font(.system(size: 31, weight: .medium, design: .rounded))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OverviewView: View {
    @Bindable var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 25) {
                    Stat(value: "\(state.activeSources.count)", label: "Connected sources", symbol: "folder.badge.gearshape")
                    Stat(value: "\(state.liveFiles.count)", label: "Versioned files & skills", symbol: "doc.text")
                    Stat(value: "\(state.changesToday)", label: "Changes today", symbol: "clock.arrow.circlepath")
                    Stat(value: "\(state.untrackedCount)", label: "Files not in Git", symbol: "exclamationmark.triangle")
                    Stat(value: "\(state.reviewCount)", label: "To review", symbol: "checklist")
                }.padding(24).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                if state.inventory.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Start with a folder.").font(.title2.weight(.semibold))
                        Text("Choose a folder containing your repositories. harnessmd finds recognized agent instructions, keeps their history, and leaves everything else alone.")
                            .foregroundStyle(.secondary).frame(maxWidth: 570, alignment: .leading)
                        HStack {
                            Button("Choose repository folder...") { state.addRoot() }.buttonStyle(.borderedProminent)
                            Button("Configure global instructions") { state.navigation = "settings" }
                        }
                    }.padding(.vertical, 16)
                }
                HStack(alignment: .top, spacing: 35) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeading("Recent activity", action: "View all") { state.navigation = "recent" }
                        if state.inventory.changes.isEmpty {
                            emptyLine(state.liveFiles.isEmpty ? "No snapshots yet. Your first scan starts the timeline." : "No changes yet. \(state.liveFiles.count) files are tracked from their first capture; edits show up here.")
                        }
                        ForEach(Array(state.inventory.changes.prefix(6))) { version in
                            Button {
                                state.selection = [version.fileID]; state.navigation = "library"
                            } label: { ActivityRow(state: state, version: version) }.buttonStyle(.plain)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeading("Worth a look", action: "Review") { state.navigation = "review" }
                        if state.openFindings.isEmpty { emptyLine("Local checks found nothing. They run after every scan.") }
                        ForEach(Array(state.openFindings.prefix(4))) { finding in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "lightbulb").foregroundStyle(.orange)
                                    Text(ReviewView.kindLabel(finding.kind)).font(.system(size: 9, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(.secondary)
                                    Spacer()
                                    GitBadge(tracked: state.gitState(finding.fileIDs))
                                }
                                Text(state.filesLabel(finding.fileIDs)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(finding.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity)
                }
                if !state.warnings.isEmpty {
                    DisclosureGroup("\(state.warnings.count) collection warnings") {
                        ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.foregroundStyle(.orange)
                }
            }.padding(26)
        }
    }
    private func sectionHeading(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.system(size: 15, weight: .semibold)); Spacer(); Button(action, action: perform).buttonStyle(.plain).font(.caption).foregroundStyle(accent) }
    }
    private func emptyLine(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12) }
}

struct ActivityRow: View {
    var state: AppState; var version: Version
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: version.blob == nil ? "doc.badge.minus" : "doc.badge.clock").font(.system(size: 17)).foregroundStyle(accent).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.fileName(version.fileID)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    if let file = state.inventory.files.first(where: { $0.id == version.fileID }) { Text(state.sourceName(file.sourceID)); Text("·") }
                    Text(version.originLabel)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(version.capturedAt, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct LibraryView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file, source, or tool", text: $state.search).textFieldStyle(.plain)
                Picker("Category", selection: $state.category) {
                    Text("All categories").tag("all")
                    ForEach(["instructions", "skills", "rules", "config", "prompts", "agents", "memories"], id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().frame(width: 145)
                Picker("Git", selection: $state.gitFilter) {
                    Text("In Git or not").tag("all")
                    Text("In Git").tag("tracked")
                    Text("Not in Git").tag("untracked")
                }.labelsHidden().frame(width: 130).help("Files not in Git have no backup but harnessmd's history")
                Button { state.openRestore() } label: { Label("Restore...", systemImage: "clock.arrow.circlepath") }
                    .disabled(state.selection.isEmpty || state.mutating)
                    .help("Restore the selected files as they were at a point in time")
                Button { state.prepareAnalysis() } label: { Label("Suggest edits...", systemImage: "pencil.line") }
                    .disabled(state.analyzing || !state.filteredFiles.contains { $0.blob != nil })
                    .help(state.selection.isEmpty ? "Ask your AI model for edits to every file shown. You see the exact request before it is sent." : "Ask your AI model for edits to the selected files. You see the exact request before it is sent.")
            }.padding(.horizontal, 22).padding(.vertical, 12)
            if let source = state.inventory.sources.first(where: { $0.id == state.navigation }) {
                HStack {
                    Text(source.root).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Toggle("Private", isOn: Binding(get: { source.isPrivate }, set: { state.updateSource(source, isPrivate: $0) })).toggleStyle(.checkbox).help("Version locally, never send to AI")
                    Toggle("Collect", isOn: Binding(get: { source.enabled }, set: { state.updateSource(source, enabled: $0) })).toggleStyle(.checkbox)
                }.padding(.horizontal, 22).padding(.bottom, 10)
            }
            Divider()
            if state.filteredFiles.isEmpty {
                ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass", description: Text("Add a repository folder, scan, or try a different filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    Table(state.filteredFiles, selection: $state.selection) {
                        TableColumn("File") { file in
                            HStack(spacing: 8) {
                                Image(systemName: file.isDirectory ? "shippingbox" : "doc.text").foregroundStyle(file.blob == nil ? .tertiary : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(state.sourceName(file.sourceID) + (file.blob == nil ? " · deleted" : "")).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5)
                        }
                        TableColumn("Tool") { file in ToolBadge(tool: file.tool) }.width(75)
                        TableColumn("Git") { file in GitBadge(tracked: state.inventory.gitTracked[file.id]) }.width(76)
                        TableColumn("Versions") { file in Text("\(state.versionCount(file.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }.width(60)
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button("Suggest edits...") { state.prepareAnalysis(ids: ids) }.disabled(ids.isEmpty || state.analyzing)
                        Button("Restore...") { state.selection = ids; state.openRestore() }.disabled(ids.isEmpty || state.mutating)
                    }
                    .frame(minWidth: 350, idealWidth: 440, maxWidth: 560, maxHeight: .infinity)
                    if let file = state.filteredFiles.first(where: { state.selection.contains($0.id) }) {
                        FileHistoryView(state: state, file: file).id(file.id).frame(minWidth: 350, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("A little history", systemImage: "clock.arrow.circlepath", description: Text("Select a file to explore its timeline and compare versions."))
                            .frame(minWidth: 320, idealWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // AppKit split panes keep their content's height unless told to fill, which pins them to the bottom.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ToolBadge: View {
    var tool: String
    var body: some View {
        Text(tool == "claude" ? "Claude" : tool == "codex" ? "Codex" : tool == "opencode" ? "OpenCode" : "Shared")
            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
            .background((tool == "claude" ? Color.orange : tool == "codex" ? accent : Color.indigo).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct GitBadge: View {
    /// Nil for global files and unreadable indexes, which show nothing.
    var tracked: Bool?
    var body: some View {
        if let tracked {
            Text(tracked ? "In Git" : "Not in Git")
                .font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
                .foregroundStyle(tracked ? Color.secondary : Color.orange)
                .background((tracked ? Color.secondary : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                .help(tracked ? "Added to Git: Git history can also restore it." : "Not in Git: harnessmd's history is its only backup.")
        }
    }
}

/// Restores a selection of files as they were at one moment, each after its own safety snapshot.
struct BatchRestoreView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Restore files to a point in time", systemImage: "clock.arrow.circlepath").font(.title2.weight(.semibold))
            Text("Each file is written back as it was at that moment, after a safety snapshot of its current content. Files that didn't exist then are left as they are; nothing is deleted. No Git commands run.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                DatePicker("As of", selection: $state.restoreDate, in: ...Date()).datePickerStyle(.compact)
                Menu("Presets") {
                    Button("1 hour ago") { state.restoreDate = Date().addingTimeInterval(-3_600) }
                    Button("Yesterday, same time") { state.restoreDate = Date().addingTimeInterval(-86_400) }
                    Button("A week ago") { state.restoreDate = Date().addingTimeInterval(-7 * 86_400) }
                }.fixedSize()
            }
            List(state.restorePlans) { plan in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.file.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(plan.sourceName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    GitBadge(tracked: state.inventory.gitTracked[plan.file.id])
                    Text(outcome(plan)).font(.caption).foregroundStyle(plan.action == .restore ? Color.primary : Color.secondary)
                        .frame(width: 210, alignment: .trailing)
                }.padding(.vertical, 3)
            }
            .listStyle(.inset)
            .overlay { if state.restorePlans.isEmpty { ProgressView() } }
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { state.showingRestore = false }.keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Restore 1 file" : "Restore \(count) files") { state.runRestore() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(count == 0 || state.mutating)
            }
        }
        .padding(24).frame(width: 740, height: 540)
        .onChange(of: state.restoreDate) { state.planRestore() }
    }

    private var count: Int { state.restorePlans.filter { $0.action == .restore }.count }
    private var summary: String {
        let idle = state.restorePlans.count - count
        return idle == 0 ? "" : "\(idle) of \(state.restorePlans.count) selected files need no restore."
    }
    private func outcome(_ plan: RestorePlan) -> String {
        switch plan.action {
        case .restore: return "Restore " + (plan.target?.capturedAt.formatted(date: .abbreviated, time: .shortened) ?? "") + " version"
        case .unchanged: return "Already matches"
        case .untracked: return "Not tracked yet then"
        case .absent: return "Didn't exist then, left as is"
        }
    }
}

struct FileHistoryView: View {
    @Bindable var state: AppState
    var file: TrackedFile
    @State private var versions: [Version] = []
    @State private var selectedVersion: String?
    @State private var content = ""
    /// Set when the selected version is shown as changes from the one before it.
    @State private var changes: DiffFile?
    @State private var showDiff = true
    @State private var restoreConfirmation = false
    private var version: Version? { versions.first { $0.id == selectedVersion } ?? versions.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.headline); Spacer(); ToolBadge(tool: file.tool) }
                Text(file.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let tracked = state.inventory.gitTracked[file.id] {
                    Label(tracked ? "In Git: Git history can also restore this file." : "Not in Git: harnessmd's history is the only backup of earlier versions.",
                          systemImage: tracked ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(tracked ? Color.secondary : Color.orange)
                }
                Picker("Version", selection: Binding(get: { version?.id ?? "" }, set: { selectedVersion = $0 })) {
                    ForEach(versions) { version in Text(version.capturedAt.formatted(date: .abbreviated, time: .standard) + " · " + version.originLabel).tag(version.id) }
                }.labelsHidden()
                HStack {
                    Picker("Display", selection: $showDiff) { Text("Diff").tag(true); Text("Content").tag(false) }.pickerStyle(.segmented).frame(width: 160)
                    Spacer()
                    Button("Suggest edits...") { state.prepareAnalysis(ids: [file.id]) }.disabled(file.blob == nil || !file.allowsAI || state.analyzing)
                        .help(file.allowsAI ? "Ask your AI model for edits to this file. You see the exact request before it is sent." : "Tool configs and memories stay local.")
                    Button("Restore...") { restoreConfirmation = true }.disabled(version?.blob == nil || state.mutating)
                }
            }.padding(18)
            Divider()
            if let changes { DiffView(files: [changes]) } else { CodeText(text: content) }
        }
        .task(id: state.versionCount(file.id)) { versions = await state.history(file.id) }
        .task(id: "\(version?.id ?? "")-\(showDiff)") { await load() }
        .confirmationDialog("Restore this version?", isPresented: $restoreConfirmation, titleVisibility: .visible) {
            Button("Restore selected version") { if let version { state.restore(version) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(file.isDirectory ? "Current content is snapshotted first. Bundled files are restored; newer files in the skill directory are preserved. No Git commands run." : "Current content is snapshotted first, then the selected version replaces the original file. No Git commands run.") }
    }
    private func load() async {
        guard let version, let engine = state.engine else { return }
        do {
            var text = ""
            if let blob = version.blob { text = try await engine.snapshot(blob: blob).displayText }
            let index = versions.firstIndex { $0.id == version.id } ?? 0
            if showDiff, index + 1 < versions.count {
                var before = ""
                if let blob = versions[index + 1].blob { before = try await engine.snapshot(blob: blob).displayText }
                changes = DiffFile(id: version.id, title: "Changes from \(versions[index + 1].capturedAt.formatted(date: .abbreviated, time: .standard))",
                                   hunks: TextDiff.hunks(before: before, after: text))
            } else if showDiff {
                // The first capture starts the timeline; an all-added diff would read like a change.
                content = "First captured \(version.capturedAt.formatted(date: .abbreviated, time: .standard)). Nothing earlier to compare, so this is the full content.\n\n" + text
                changes = nil
            } else { content = version.blob == nil ? "This version records a deletion." : text; changes = nil }
        } catch { content = "Could not load snapshot: " + error.localizedDescription; changes = nil }
    }
}

extension Version {
    /// What happened, in words. The first capture starts tracking; it is not a change.
    var originLabel: String {
        if blob == nil { return origin == "pre_restore" ? "missing before restore" : "deleted" }
        switch origin {
        case "initial": return "first captured"
        case "scan", "watcher": return "changed"
        case "pre_restore": return "before restore"
        case "restore": return "restored"
        case "pre_apply": return "before proposal"
        case "apply": return "proposal applied"
        case "rollback": return "rolled back"
        default: return origin.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct RecentView: View {
    @Bindable var state: AppState
    var body: some View {
        if state.inventory.changes.isEmpty {
            ContentUnavailableView("Nothing has changed yet", systemImage: "clock", description: Text(state.liveFiles.isEmpty ? "Scan a repository to start a permanent version history." : "Files are tracked from their first capture. Edits, restores, and applied proposals show up here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(state.inventory.changes) { version in
                Button { state.selection = [version.fileID]; state.navigation = "library" } label: { ActivityRow(state: state, version: version).padding(.vertical, 7) }.buttonStyle(.plain)
            }.listStyle(.inset)
        }
    }
}
