import SwiftUI
import HarnessKit

/// One thing to review: a model's diff, or a local check.
enum ReviewItem: Identifiable {
    case proposal(Proposal)
    case finding(Finding)

    var id: String {
        switch self {
        case .proposal(let proposal): "proposal|" + proposal.id
        case .finding(let finding): "finding|" + finding.id
        }
    }
    var fileIDs: [String] {
        switch self {
        case .proposal(let proposal): proposal.edits.map(\.fileID)
        case .finding(let finding): finding.fileIDs
        }
    }
    var summary: String {
        switch self {
        case .proposal(let proposal): MarkdownView.headline(of: proposal.rationale)
        case .finding(let finding): finding.title + " " + finding.detail
        }
    }
    /// "1 change" or the check's kind, plus the status once decided.
    var label: String {
        switch self {
        case .proposal(let proposal): proposal.kicker + (proposal.status == "pending" ? "" : " · " + proposal.statusLabel)
        case .finding(let finding): ReviewView.kindLabel(finding.kind)
        }
    }
    var isProposal: Bool { if case .proposal = self { true } else { false } }
}

/// One row in Review: every diff and check that shares a file, so a file is listed once.
struct ReviewGroup: Identifiable {
    let id: String
    let fileIDs: [String]
    let items: [ReviewItem]

    /// Items connected through shared files form one group; groups keep the order of their first item.
    static func grouped(_ items: [ReviewItem]) -> [ReviewGroup] {
        connectedGroups(items.map(\.fileIDs)).map { indices in
            let items = indices.map { items[$0] }
            var files: [String] = []
            for file in items.flatMap(\.fileIDs) where !files.contains(file) { files.append(file) }
            return ReviewGroup(id: files.sorted().joined(separator: "|"), fileIDs: files, items: items)
        }
    }
}

/// AI diffs and local checks in one list, filtered by kind, Git state, and whether they still need a decision.
struct ReviewView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file, repository, or text", text: $state.reviewSearch).textFieldStyle(.plain)
                Picker("Show", selection: $state.reviewKind) {
                    Text("AI changes and checks").tag("all")
                    Text("AI changes").tag("ai")
                    Text("Local checks").tag("checks")
                }.labelsHidden().frame(width: 175)
                Picker("Git", selection: $state.reviewGit) {
                    Text("In Git or not").tag("all")
                    Text("In Git").tag("tracked")
                    Text("Not in Git").tag("untracked")
                }.labelsHidden().frame(width: 125)
                Picker("State", selection: $state.reviewDone) {
                    Text("To review").tag(false)
                    Text("Done").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }.padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            let groups = state.reviewGroups
            let selected = groups.filter { state.reviewRows.contains($0.id) }
            if let first = groups.first {
                HSplitView {
                    List(groups, selection: $state.reviewRows) { group in ReviewRow(state: state, group: group).tag(group.id) }
                        // Command-A selects every row natively; Control-A does too, for keyboards set up that way.
                        .onKeyPress(keys: ["a"]) { press in
                            guard press.modifiers.contains(.control) else { return .ignored }
                            state.reviewRows = Set(groups.map(\.id))
                            return .handled
                        }
                        // Where Control-click selects; see `AppState.installControlClickSelection`.
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { state.reviewListFrame = proxy.frame(in: .global) }
                                .onChange(of: proxy.frame(in: .global)) { _, frame in state.reviewListFrame = frame }
                        })
                        .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)
                    Group {
                        if selected.count > 1 { ReviewBulkDetail(state: state, groups: selected) }
                        else { ReviewGroupDetail(state: state, group: selected.first ?? first) }
                    }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.seal", description: Text(emptyDetail))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var filtered: Bool { state.reviewKind != "all" || state.reviewGit != "all" || !state.reviewSearch.isEmpty }
    private var emptyTitle: String { filtered ? "Nothing matches" : state.reviewDone ? "Nothing decided yet" : "Nothing to review" }
    private var emptyDetail: String {
        if filtered { return "Try other filters." }
        if state.reviewDone { return "Applied, rejected, and fine items appear here." }
        return "Local checks run after every scan. In All files, choose Suggest edits to get changes from your AI model as diffs."
    }

    nonisolated static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "sync": "Out of sync"
        case "stale": "Missing paths"
        default: kind
        }
    }
}

private struct ReviewRow: View {
    var state: AppState
    var group: ReviewGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                kicker.font(.system(size: 9, weight: .semibold)).tracking(1).textCase(.uppercase).lineLimit(1)
                Spacer(minLength: 4)
                GitBadge(tracked: state.gitState(group.fileIDs))
            }
            Text(state.filesLabel(group.fileIDs)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(MarkdownView.inline(subtitle)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(footer).lineLimit(1)
                Spacer()
                if let proposal { Text(proposal.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())) }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
    private var proposal: Proposal? {
        for item in group.items { if case .proposal(let proposal) = item { return proposal } }
        return nil
    }
    /// Every item in the row, changes in the accent color and checks in orange.
    private var kicker: Text {
        group.items.enumerated().reduce(Text("")) { text, entry in
            (entry.offset == 0 ? text : text + Text(" · ").foregroundStyle(.secondary)) + Text(entry.element.label).foregroundStyle(entry.element.isProposal ? accent : .orange)
        }
    }
    private var subtitle: String {
        if let proposal { return MarkdownView.headline(of: proposal.rationale) }
        if case .finding(let finding) = group.items.first { return finding.title }
        return ""
    }
    private var footer: String {
        if let proposal { return proposal.model + " · " + proposal.statusLabel }
        if case .finding(let finding) = group.items.first, state.inventory.dismissed.contains(finding.key) { return "Local check · Fine" }
        return "Local check"
    }
}

/// Several rows selected: one decision for all of them.
private struct ReviewBulkDetail: View {
    @Bindable var state: AppState
    var groups: [ReviewGroup]
    @State private var confirming = false
    var body: some View {
        let items = groups.flatMap(\.items)
        let diffs = items.compactMap { item -> Proposal? in if case .proposal(let proposal) = item, proposal.status == "pending" { proposal } else { nil } }
        let checks = items.filter { if case .finding(let finding) = $0 { !state.inventory.dismissed.contains(finding.key) } else { false } }
        let returnable = items.filter {
            switch $0 {
            case .proposal(let proposal): proposal.status == "kept"
            case .finding(let finding): state.inventory.dismissed.contains(finding.key)
            }
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("\(groups.count) files selected").font(.title3.weight(.semibold))
            Text(state.reviewDone ? "\(returnable.count) can go back to review." : "\(diffs.count) \(diffs.count == 1 ? "diff" : "diffs") waiting, \(checks.count) \(checks.count == 1 ? "check" : "checks").")
                .foregroundStyle(.secondary)
            HStack {
                if state.reviewDone {
                    Button("Put back for review") { state.decideAll(groups, .putBack) }.disabled(returnable.isEmpty || state.mutating)
                } else {
                    Button("It's fine") { state.decideAll(groups, .fine) }.disabled(diffs.isEmpty && checks.isEmpty || state.mutating)
                        .help("Hides the checks and rejects the diffs, remembering their points for later analyses.")
                    Button("Reject diffs") { state.decideAll(groups, .reject) }.disabled(diffs.isEmpty || state.mutating)
                    Button("Accept & apply \(diffs.count == 1 ? "1 diff" : "\(diffs.count) diffs")...") { confirming = true }
                        .buttonStyle(.borderedProminent).disabled(diffs.isEmpty || state.mutating)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        HStack(spacing: 8) {
                            Text(state.filesLabel(group.fileIDs)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            GitBadge(tracked: state.gitState(group.fileIDs))
                            Spacer()
                            Text(group.items.map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Apply \(diffs.count == 1 ? "1 diff" : "\(diffs.count) diffs")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply") { state.decideAll(groups, .accept) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each file is checked for changes and snapshotted before writing; a file that changed since is skipped and listed. No Git commands run.")
        }
    }
}

/// A row's items: tabs when there are several, such as a waiting edit and the check it fixes.
private struct ReviewGroupDetail: View {
    @Bindable var state: AppState
    var group: ReviewGroup
    var body: some View {
        let shown = group.items.first { $0.id == state.reviewSelection } ?? group.items[0]
        VStack(spacing: 0) {
            if group.items.count > 1 {
                let picker = Picker("Item", selection: Binding(get: { shown.id }, set: { state.reviewSelection = $0 })) {
                    ForEach(group.items) { Text($0.label).tag($0.id) }
                }.labelsHidden()
                Group {
                    if group.items.count <= 4 { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
                }
                .padding(.horizontal, 20).padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                switch shown {
                case .proposal(let proposal): ProposalDetail(state: state, proposal: proposal)
                case .finding(let finding): FindingDetail(state: state, finding: finding)
                }
            }.id(shown.id)
        }
    }
}

private struct FindingDetail: View {
    @Bindable var state: AppState
    var finding: Finding
    private var fine: Bool { state.inventory.dismissed.contains(finding.key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(ReviewView.kindLabel(finding.kind)).font(.system(size: 9, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(.orange)
                Text(finding.title).font(.headline)
                Text("Local check: found on this Mac, no model involved.").font(.caption).foregroundStyle(.secondary)
                if let waiting = state.waitingProposal(for: finding.fileIDs), !fine {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(accent)
                        Text("An edit for this file is waiting: " + MarkdownView.headline(of: waiting.rationale)).font(.callout).lineLimit(2)
                        Spacer()
                        Button("Show edit") {
                            if state.reviewKind == "checks" { state.reviewKind = "all" }
                            state.focus("proposal|" + waiting.id)
                        }.buttonStyle(.borderedProminent)
                    }
                    .padding(10).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Spacer()
                    if fine {
                        Text("Fine").font(.caption.weight(.semibold))
                        Button("Show again") { state.setFine(finding, false) }.disabled(state.mutating)
                    } else {
                        Button("It's fine") { state.setFine(finding, true) }.disabled(state.mutating)
                            .help("Hides this check for these files. It comes back if the problem changes, such as another missing path.")
                        if state.waitingProposal(for: finding.fileIDs) == nil {
                            Button("Suggest a fix...") { state.fix(finding) }.buttonStyle(.borderedProminent).disabled(state.analyzing)
                                .help("Asks your AI model for a fix, with this check and what's on disk as the task. The fix comes back here as a diff.")
                        } else {
                            Button("Suggest another fix...") { state.fix(finding, again: true) }.disabled(state.analyzing)
                                .help("A new fix replaces the edit waiting for this file.")
                        }
                    }
                }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(finding.detail).textSelection(.enabled)
                    Text("Files").font(.headline).padding(.top, 6)
                    ForEach(finding.fileIDs, id: \.self) { id in
                        HStack(spacing: 8) {
                            Text(state.fileLabel(id)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            GitBadge(tracked: state.inventory.gitTracked[id])
                            Spacer()
                            Button("History") { state.selection = [id]; state.navigation = "library" }.controlSize(.small)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
