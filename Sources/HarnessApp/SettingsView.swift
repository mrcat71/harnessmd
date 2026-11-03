import SwiftUI
import AppKit
import ServiceManagement
import HarnessKit

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var saved = false
    @State private var newPattern = ""
    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                CheckForUpdatesCommand()
                if case .unavailable(let reason) = AppUpdater.shared.state {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { AppUpdater.shared.automaticallyChecksForUpdates },
                        set: { AppUpdater.shared.automaticallyChecksForUpdates = $0 }
                    ))
                    Toggle("Download updates in the background", isOn: Binding(
                        get: { AppUpdater.shared.automaticallyDownloadsUpdates },
                        set: { AppUpdater.shared.automaticallyDownloadsUpdates = $0 }
                    )).disabled(!AppUpdater.shared.automaticallyChecksForUpdates)
                    Text("Updates are verified before extraction. Relaunch to install, or leave a prepared update for the next quit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Collection") {
                ForEach(state.settings.roots, id: \.self) { root in
                    HStack {
                        Label(root, systemImage: "folder").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Remove") {
                            state.settings.roots.removeAll { $0 == root }
                            Task { await state.saveSettings(); await state.scan() }
                        }
                    }
                }
                Button("Add repository folder...") { state.addRoot() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra instruction files")
                    ForEach(state.settings.customPatterns, id: \.self) { pattern in
                        HStack {
                            Text(pattern).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Remove") {
                                state.settings.customPatterns.removeAll { $0 == pattern }
                                Task { await state.saveSettings(); await state.scan() }
                            }
                        }
                    }
                    HStack {
                        TextField("Pattern", text: $newPattern, prompt: Text("GEMINI.md or .kilocode/rules/*.md")).labelsHidden()
                            .font(.system(.callout, design: .monospaced)).onSubmit(addPattern)
                        Button("Add", action: addPattern).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Collected in repositories as instructions, next to AGENTS.md and CLAUDE.md. A name matches in any folder; a path with / matches from the repository root, where * stays within one folder and ** spans folders. Denied names and credential-like contents are still excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Collect global Claude, Codex, shared skills, and OpenCode files", isOn: $state.settings.includeGlobals)
                    .onChange(of: state.settings.includeGlobals) { _, _ in Task { await state.saveSettings(); await state.scan() } }
                Text("Global locations: ~/.claude, ~/.codex, ~/.agents, ~/.agent-skills, ~/.config/opencode, using each tool's known files only (no caches, plugins, or sessions). Credential-like contents, denied filenames, and symlinks are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Discover new files", selection: $state.settings.sweepSeconds) {
                    Text("Every minute").tag(60.0)
                    Text("Every 10 minutes").tag(600.0)
                    Text("Every hour").tag(3600.0)
                }.onChange(of: state.settings.sweepSeconds) { _, _ in Task { await state.saveSettings() } }
                HStack {
                    Text("Existing files are watched between scans.").foregroundStyle(.secondary)
                    Spacer()
                    Button(state.settings.paused ? "Resume watching" : "Pause watching") { state.togglePause() }
                }
            }
            Section("AI model") {
                Picker("Backend", selection: Binding(get: { state.settings.backend }, set: { state.selectBackend($0); saved = false })) {
                    ForEach(Backend.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if backend.usesBinary {
                    TextField("CLI binary (absolute path)", text: $state.settings.binary)
                } else {
                    TextField("Ollama server", text: $state.settings.ollamaURL)
                }
                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        TextField("Model", text: $state.settings.model, prompt: Text(backend == .ollama ? "Required" : "CLI default")).labelsHidden()
                        Menu {
                            if state.availableModels.isEmpty { Text(state.loadingModels ? "Loading..." : "No models found") }
                            ForEach(state.availableModels, id: \.self) { model in Button(model) { state.settings.model = model } }
                            Divider()
                            Button("Refresh list") { state.refreshModels() }
                        } label: { Image(systemName: "list.bullet") }
                            .menuStyle(.borderlessButton).fixedSize().help("Pick a model")
                    }
                }
                Picker("Default depth", selection: $state.settings.thoroughAnalysis) {
                    Text("Quick").tag(false)
                    Text("Thorough").tag(true)
                }
                Picker("Thorough effort", selection: $state.settings.effort) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
                Text(quickNote).font(.caption).foregroundStyle(.secondary)
                TextField("Timeout in seconds (1-600)", value: $state.settings.timeout, format: .number)
                    .help("How long the backend may stay silent. A model that is still thinking or writing keeps going, up to \(Int(AIService.runLimit / 60)) minutes per request.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default instructions")
                    TextEditor(text: $state.settings.analysisInstructions)
                        .font(.callout).frame(minHeight: 64)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("What to analyze and change. Empty uses: \(AIService.defaultInstructions) The model answers with changes you review as a diff, and the preview lets you change these instructions for each request.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save AI settings") {
                        if let problem = validation { state.error = problem; return }
                        Task { await state.saveSettings(); saved = true }
                    }
                    if saved { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
                Text(backendNote + " Requests require a payload preview and explicit approval. Mark sources Private to exclude them. Skill analysis includes SKILL.md only; tool configs, Codex exec policies, memories, and bundled scripts stay local.")
                    .font(.caption).foregroundStyle(backend == .codex ? Color.orange : Color.secondary)
                if !state.inventory.invocations.isEmpty {
                    DisclosureGroup("AI activity log (\(state.inventory.invocations.count))") {
                        ForEach(Array(state.inventory.invocations.prefix(20))) { invocation in
                            HStack {
                                Text(invocation.date, format: .dateTime.month().day().hour().minute())
                                Text(invocation.backend)
                                Text("\(invocation.fileIDs.count) files")
                                Spacer()
                                Text(invocation.status)
                            }.font(.caption)
                        }
                    }
                }
            }
            Section("Background & storage") {
                // Only user input reaches the setter, so a status refresh can't re-trigger unregister.
                Toggle("Launch at login", isOn: Binding(get: { [.enabled, .requiresApproval].contains(state.loginStatus) }, set: { state.setLogin($0) }))
                if state.loginStatus == .requiresApproval {
                    HStack {
                        Text("Waiting for approval in System Settings > General > Login Items.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Text("The app stays in your menu bar when the dashboard closes. Login registration requires the packaged .app; macOS may ask you to approve it in Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Store") { Text(state.storeURL.path).font(.caption.monospaced()).textSelection(.enabled) }
                Button("Reveal local store in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: state.storeURL.path) }
                Text("Snapshots are permanent and unencrypted. Back up this directory to preserve your history. Removing a scan folder stops its collection but keeps existing history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onAppear {
            state.refreshLoginStatus()
            // Listing OpenCode models runs its CLI, so that one waits for an explicit refresh.
            if state.availableModels.isEmpty && backend != .opencode { state.refreshModels() }
        }
    }

    private func addPattern() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard Scanner.globRegex(pattern) != nil else {
            state.error = "Use a file name like GEMINI.md or a path like .kilocode/rules/*.md, without .. or a leading /."
            return
        }
        newPattern = ""
        guard !state.settings.customPatterns.contains(pattern) else { return }
        state.settings.customPatterns.append(pattern)
        Task { await state.saveSettings(); await state.scan() }
    }

    private var backend: Backend { Backend(rawValue: state.settings.backend) ?? .claude }
    private var quickNote: String {
        let quick = AIService.quickEffort(for: backend.rawValue).map { "effort \($0)" } ?? "the effort above, since its variants depend on the model"
        return "Quick analysis uses \(quick) and takes seconds per file on local models. Thorough uses the effort above and finds more, but a thinking model can take minutes per file."
    }
    /// A stored effort the list doesn't know stays selectable.
    private var efforts: [String] {
        let known = backend.efforts
        return known.contains(state.settings.effort) || state.settings.effort.isEmpty ? known : known + [state.settings.effort]
    }
    private var validation: String? {
        let settings = state.settings
        guard settings.timeout.isFinite, (1...600).contains(settings.timeout) else { return "Use a timeout from 1 to 600 seconds." }
        if backend.usesBinary && !settings.binary.hasPrefix("/") { return "Use an absolute CLI path." }
        if backend == .ollama && settings.model.isEmpty { return "Choose an installed Ollama model." }
        if !settings.model.isEmpty && !AIService.isName(settings.model) { return "A model name can't contain spaces or start with a dash." }
        return nil
    }
    private var backendNote: String {
        switch backend {
        case .claude: return "Claude Code runs without tools, MCP servers, or your settings, using its existing sign-in."
        case .codex: return "Codex runs read-only with your config.toml ignored and browser, computer-use, plugin, and hook features off, but its shell can still read files on this Mac and send them to OpenAI. Prefer another backend for untrusted repositories."
        case .opencode: return "OpenCode runs with deny-all permissions, no plugins or MCP servers, and only your provider definitions."
        case .ollama:
            return AIService.isLoopback(state.settings.ollamaURL)
                ? "Runs on your local Ollama server; the payload stays on this Mac."
                : "This server is not on this Mac, so the payload leaves the machine."
        }
    }
}
