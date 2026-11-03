import SwiftUI
import HarnessKit

/// One file's changes, with the model's reason for each change when it gave one.
struct DiffFile: Identifiable {
    var id: String
    var title: String
    var hunks: [TextDiff.Hunk]
    var notes: [ChangeNote] = []
    var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}

/// A unified diff as Git shows it: hunks with context and line numbers, changed words marked inside
/// modified lines, and each change's reason above the hunk that shows it.
struct DiffView: View {
    private enum Row {
        case summary(String), file(DiffFile), note(String), hunk(String), line(TextDiff.Line), message(String)
    }
    private let rows: [Row]
    private let gutter: CGFloat

    init(summary: String? = nil, files: [DiffFile]) {
        var rows: [Row] = []
        if let summary, !summary.isEmpty { rows.append(.summary(summary)) }
        for file in files {
            rows.append(.file(file))
            if file.hunks.isEmpty { rows.append(.message("No content changes.")); continue }
            let placement = Self.place(file.notes, in: file.hunks)
            for (index, hunk) in file.hunks.enumerated() {
                rows += (placement[index] ?? []).map { .note($0.text) }
                rows.append(.hunk(hunk.header))
                rows += hunk.lines.map(Row.line)
            }
        }
        self.rows = rows
        let largest = files.flatMap(\.hunks).map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        gutter = CGFloat(String(largest).count) * 7 + 12
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in row(rows[index]) }
            }
            .textSelection(.enabled)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func row(_ row: Row) -> some View {
        switch row {
        case .summary(let text):
            MarkdownView(text: text).padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        case .file(let file):
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(file.title).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("+\(file.added)").foregroundStyle(.green)
                Text("-\(file.removed)").foregroundStyle(.red)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
            .padding(.top, 10)
        case .note(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(accent)
                Text(MarkdownView.inline(text)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(accent.opacity(0.09))
        case .hunk(let header):
            Text(header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
        case .line(let line):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(line.old.map(String.init) ?? "").frame(width: gutter, alignment: .trailing).foregroundStyle(.tertiary)
                Text(line.new.map(String.init) ?? "").frame(width: gutter, alignment: .trailing).foregroundStyle(.tertiary)
                Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ").frame(width: 22).foregroundStyle(tint(line.kind))
                Text(content(line)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.vertical, 1).padding(.trailing, 14)
            .background(tint(line.kind).opacity(line.kind == .context ? 0 : 0.12))
        case .message(let text):
            Text(text).font(.callout).foregroundStyle(.secondary).padding(14)
        }
    }

    private func content(_ line: TextDiff.Line) -> AttributedString {
        var result = AttributedString(line.spans.isEmpty ? (line.text.isEmpty ? " " : line.text) : "")
        for span in line.spans {
            var part = AttributedString(span.text)
            if span.changed { part.backgroundColor = tint(line.kind).opacity(0.3) }
            result.append(part)
        }
        if line.noNewline {
            var marker = AttributedString("  (no newline at end of file)")
            marker.foregroundColor = .secondary
            result.append(marker)
        }
        return result
    }

    private func tint(_ kind: TextDiff.Line.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .context: .secondary
        }
    }

    /// Each note goes above the hunk that shows its line, or the nearest one.
    private static func place(_ notes: [ChangeNote], in hunks: [TextDiff.Hunk]) -> [Int: [ChangeNote]] {
        func distance(_ line: Int, _ hunk: TextDiff.Hunk) -> Int {
            let end = hunk.newStart + max(hunk.newCount, 1) - 1
            return line < hunk.newStart ? hunk.newStart - line : max(0, line - end)
        }
        var placement: [Int: [ChangeNote]] = [:]
        for note in notes {
            guard let index = hunks.indices.min(by: { distance(note.line, hunks[$0]) < distance(note.line, hunks[$1]) }) else { continue }
            placement[index, default: []].append(note)
        }
        return placement
    }
}

/// Monospaced text without diff colors: payload previews and file content.
struct CodeText: View {
    var text: String
    var body: some View {
        ScrollView(.vertical) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true).padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}
