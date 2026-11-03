import SwiftUI
import AppKit
import HarnessKit

struct AIPreviewView: View {
    @Bindable var state: AppState
    @State private var instructions = ""
    @State private var oneByOne = true
    @State private var thorough = false
    /// Cross-file tasks need every file in one request; per-file reviews are faster one by one.
    private static let presets: [(name: String, text: String, together: Bool)] = [
        ("Review and improve", AIService.defaultInstructions, false),
        ("Resolve contradictions", "Find instructions that contradict each other within or across these files. Resolve each conflict, keeping the more specific or more recent rule, and say in why which side you kept.", true),
        ("Consolidate repeated guidance", "Find guidance repeated across these files. Keep the fullest copy in the most general file and replace the other copies with a one-line pointer to it.", true),
        ("Tighten and shorten", "Make these instructions shorter and more precise without changing what they require. Remove filler, repetition, and vague rules.", false),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Suggest edits", systemImage: "pencil.line").font(.title2.weight(.semibold))
            if let request = state.analysisPreview, let outgoing = state.outgoingAnalysis {
                Text(overview(outgoing)).font(.callout).foregroundStyle(.secondary)
                if !request.repeats.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(request.repeats.count == request.inputs.count ? "Analyze again" : "Also analyze the \(request.repeats.count) already analyzed", isOn: $state.analysisRepeats)
                        Text((request.repeats.count == 1 ? "1 file was" : "\(request.repeats.count) files were") + " already analyzed with these instructions and haven't changed since. Their results are in Review; a new diff replaces the one waiting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Picker("Depth", selection: $thorough) {
                        Text("Quick").tag(false)
                        Text("Thorough").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Text(thorough ? "Thinks first, with the effort from Settings. Finds more; on local models it takes minutes per file."
                         : "No extended thinking: seconds per file on local models. Catches the clearer problems.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if request.inputs.count > 1 {
                    Picker("Requests", selection: $oneByOne) {
                        Text("One file per request").tag(true)
                        Text("All files in one request").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    Text(oneByOne ? "Faster, and each file's result appears as soon as it's ready. Use one request to compare files with each other." : "Needed to compare files with each other, such as contradictions or shared skills. Slower for many files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Instructions").font(.headline)
                        Spacer()
                        Menu("Presets") {
                            ForEach(Self.presets, id: \.name) { preset in
                                Button(preset.name) { instructions = preset.text; oneByOne = !preset.together }
                            }
                        }.fixedSize()
                    }
                    TextEditor(text: $instructions)
                        .font(.callout).frame(height: 72)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text(instructionsHint).font(.caption).foregroundStyle(.secondary)
                    if let problem = state.previewProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
                Text(destination(request.settings)).font(.callout).foregroundStyle(request.settings.backend == Backend.codex.rawValue ? Color.orange : Color.primary)
                if oneByOne && outgoing.inputs.count > 1 {
                    Text("Showing request 1 of \(outgoing.inputs.count); the others carry the same instructions with their own file.").font(.caption).foregroundStyle(.secondary)
                }
                CodeText(text: outgoing.inputs.isEmpty ? "Nothing to send: every selected file was already analyzed with these instructions." : shownPrompt(outgoing)).frame(minHeight: 200)
                if !request.excluded.isEmpty {
                    DisclosureGroup("\(request.excluded.count) selected files excluded") {
                        ForEach(request.excluded, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    }.font(.caption)
                }
                HStack {
                    Text("Private sources, configs, memories, and bundled skill scripts are excluded.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { state.showingPreview = false }.keyboardShortcut(.cancelAction)
                    Button("Send") {
                        // Send exactly the instructions on screen, even inside the edit debounce.
                        state.updatePreview(instructions: instructions, oneByOne: oneByOne, thorough: thorough)
                        state.runAnalysis()
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(state.previewProblem != nil || outgoing.inputs.isEmpty)
                }
            }
        }
        .padding(24).frame(width: 840, height: 700)
        .onAppear {
            instructions = state.analysisPreview?.instructions ?? ""
            oneByOne = state.analysisOneByOne
            thorough = state.analysisPreview?.thorough ?? false
        }
        .task(id: "\(oneByOne)|\(thorough)|\(instructions)") {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            state.updatePreview(instructions: instructions, oneByOne: oneByOne, thorough: thorough)
        }
    }

    private func overview(_ request: AnalysisRequest) -> String {
        let files = request.inputs.count == 1 ? "1 file" : "\(request.inputs.count) files"
        let requests = oneByOne && request.inputs.count > 1 ? "\(request.inputs.count) requests" : "1 request of \(request.bytes.formatted()) bytes"
        return files + " · " + requests + " · " + summary(request.settings, effort: thorough ? request.settings.effort : AIService.quickEffort(for: request.settings.backend) ?? request.settings.effort)
    }

    /// In one-by-one mode the first per-file request; otherwise the single combined one.
    private func shownPrompt(_ request: AnalysisRequest) -> String {
        guard oneByOne, request.inputs.count > 1 else { return request.prompt }
        do { return try request.perFile().first?.prompt ?? request.prompt }
        catch { return error.localizedDescription }
    }

    private var instructionsHint: String {
        let answer = "The model answers with changes, shown as a diff with a reason for each. Nothing is written until you accept."
        return instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty uses: " + AIService.defaultInstructions + " " + answer : answer
    }

    private func summary(_ settings: AppSettings, effort: String) -> String {
        let backend = Backend(rawValue: settings.backend)?.title ?? settings.backend
        return backend + " / " + (settings.model.isEmpty ? "default model" : settings.model) + (effort.isEmpty ? "" : " · effort \(effort)")
    }

    private func destination(_ settings: AppSettings) -> String {
        switch Backend(rawValue: settings.backend) {
        case .ollama:
            return AIService.isLoopback(settings.ollamaURL)
                ? "This exact payload goes to your Ollama server on this Mac and doesn't leave the machine. Proposals are reviewed separately before any edits."
                : "This exact payload goes to the Ollama server at \(settings.ollamaURL), outside this Mac. Proposals are reviewed separately before any edits."
        case .codex:
            return "This exact payload goes through Codex to OpenAI. Codex can still run read-only shell commands, so it may read other files on this Mac and send them too. Proposals are reviewed separately before any edits."
        default:
            return "This exact payload will be sent through your local CLI to its configured AI provider. Your CLI may retain logs and use paid quota. Tools are disabled; proposals are reviewed separately before any edits."
        }
    }
}

extension Proposal {
    var statusLabel: String {
        switch status {
        case "accepted": "Applied"
        case "kept": "Fine as is"
        case "replaced": "Replaced by a newer one"
        default: status.capitalized
        }
    }
    var kicker: String {
        // Whole-file edits from before change notes count once.
        let count = edits.reduce(0) { $0 + max($1.notes.count, 1) }
        return count == 1 ? "1 change" : "\(count) changes"
    }
}

struct ProposalDetail: View {
    @Bindable var state: AppState
    var proposal: Proposal
    @State private var files: [DiffFile] = []
    @State private var patch = ""
    @State private var loadError: String?
    @State private var copied = false
    @State private var confirming = false
    private var targets: [(name: String, global: Bool)] {
        proposal.edits.map { edit in
            let file = state.inventory.files.first { $0.id == edit.fileID }
            let source = file.flatMap { file in state.inventory.sources.first { $0.id == file.sourceID } }
            return (state.fileLabel(edit.fileID), source?.isGlobal ?? false)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(state.filesLabel(proposal.edits.map(\.fileID))).font(.headline).textSelection(.enabled)
                    GitBadge(tracked: state.gitState(proposal.edits.map(\.fileID)))
                }
                Text(proposal.note).font(.caption).foregroundStyle(.secondary)
                if !proposal.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("Your instructions") {
                        Text(proposal.instructions).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                }
                if proposal.status == "kept" {
                    Label("Later analyses of these files are asked to leave these points as they are.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                if targets.contains(where: \.global) {
                    Label("Edits global instructions that every agent session loads.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Label(proposal.model, systemImage: "cpu").font(.caption)
                    Spacer()
                    Button(copied ? "Copied" : "Copy patch", action: copyPatch).disabled(patch.isEmpty)
                        .help("Copies the changes as a patch that git apply accepts from the repository root.")
                    if proposal.status == "pending" {
                        Button("Reject") { state.decide(proposal, accept: false) }.disabled(state.mutating)
                            .help("Rejects this proposal only.")
                        Button("It's fine") { state.keep(proposal) }.disabled(state.mutating)
                            .help("Rejects this proposal and asks later analyses of these files to leave these points as they are.")
                        Button("Accept & apply...") { confirming = true }.buttonStyle(.borderedProminent).disabled(state.mutating)
                    } else {
                        Text(proposal.statusLabel).font(.caption.weight(.semibold))
                        if proposal.status == "kept" {
                            Button("Reopen") { state.reopen(proposal) }.disabled(state.mutating)
                                .help("Puts it back in review; later analyses may suggest these points again.")
                        }
                    }
                }
            }.padding(20)
            Divider()
            if let loadError {
                Text(loadError).foregroundStyle(.red).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DiffView(summary: proposal.rationale, files: files)
            }
        }
        .task {
            do {
                var files: [DiffFile] = [], patches: [String] = []
                for edit in proposal.edits {
                    let file = state.inventory.files.first { $0.id == edit.fileID }
                    let snapshot = try await state.engine?.snapshot(blob: edit.baseBlob)
                    let before = snapshot?.entries[file?.isDirectory == true ? "SKILL.md" : ""].map { String(decoding: $0, as: UTF8.self) } ?? ""
                    files.append(DiffFile(id: edit.fileID, title: state.fileLabel(edit.fileID), hunks: TextDiff.hunks(before: before, after: edit.content), notes: edit.notes))
                    if let file { patches.append(TextDiff.patch(before: before, after: edit.content, path: file.path + (file.isDirectory ? "/SKILL.md" : ""))) }
                }
                self.files = files; patch = patches.joined()
            } catch { loadError = "Could not load proposal: " + error.localizedDescription }
        }
        .confirmationDialog("Apply \(proposal.edits.count == 1 ? "these changes" : "changes to \(proposal.edits.count) files")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Accept proposal") { state.decide(proposal, accept: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Targets: " + targets.map(\.name).joined(separator: ", ") + ". "
                 + (targets.contains(where: \.global) ? "Global instructions apply to every agent session. " : "")
                 + "All targets are checked for changes and snapshotted before writing. A changed file blocks the proposal. No Git commands run.")
        }
    }

    private func copyPatch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(patch, forType: .string)
        copied = true
    }
}

/// Renders the Markdown models write: headings, bullets, code fences, and inline formatting.
struct MarkdownView: View {
    var text: String
    private enum Block { case heading(String), bullet(String, Int), code(String), paragraph(String), gap }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let line): Text(Self.inline(line)).font(.headline).padding(.top, 6)
                case .bullet(let line, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(Self.inline(line)) }.padding(.leading, CGFloat(depth) * 14)
                case .code(let code):
                    Text(code).font(.system(size: 11, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                case .paragraph(let line): Text(Self.inline(line))
                case .gap: Color.clear.frame(height: 2)
                }
            }
        }.textSelection(.enabled)
    }

    private var blocks: [Block] {
        var result: [Block] = [], code: [String]?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code { result.append(.code(open.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { result.append(.gap) }
            else if trimmed.hasPrefix("#") { result.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))) }
            else if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
                result.append(.bullet(String(trimmed.dropFirst(marker.count)), (line.count - line.drop { $0 == " " }.count) / 2))
            }
            else { result.append(.paragraph(trimmed)) }
        }
        if let open = code { result.append(.code(open.joined(separator: "\n"))) }
        return result
    }

    /// Inline emphasis, code, and links; malformed Markdown renders as plain text.
    static func inline(_ text: String) -> AttributedString {
        do { return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) }
        catch { return AttributedString(text) }
    }

    /// The first meaningful line, without Markdown markers, for list rows.
    nonisolated static func headline(of text: String) -> String {
        let line = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        return String(line.drop { "#-*+ ".contains($0) })
    }
}
