import Foundation

/// Git-style line diffs: hunks with context, line numbers, and changed words marked within modified lines.
public enum TextDiff {
    public struct Span: Hashable, Sendable {
        public var text: String
        public var changed: Bool
    }

    public struct Line: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case context, added, removed }
        public var kind: Kind
        /// 1-based line numbers in the old and new text; nil on the side the line doesn't exist.
        public var old: Int?
        public var new: Int?
        public var text: String
        /// For a modified line, its words with the changed ones marked; empty when the whole line is new, gone, or unchanged.
        public var spans: [Span] = []
        /// The text ends on this line without a final newline.
        public var noNewline = false
    }

    public struct Hunk: Hashable, Sendable {
        public var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        public var lines: [Line]
        public var header: String { "@@ -\(Self.range(oldStart, oldCount)) +\(Self.range(newStart, newCount)) @@" }
        static func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
    }

    private struct Key: Hashable { var text: String; var open: Bool }

    /// Lines split on LF only, so a CRLF line keeps its CR and the patch still applies.
    private static func split(_ text: String) -> [Key] {
        guard !text.isEmpty else { return [] }
        let closed = text.utf8.last == 0x0A
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if closed { lines.removeLast() }
        return lines.enumerated().map { Key(text: $0.element, open: !closed && $0.offset == lines.count - 1) }
    }

    /// CollectionDifference avoids a quadratic LCS table for large instruction files.
    public static func hunks(before: String, after: String, context: Int = 3) -> [Hunk] {
        let old = split(before), new = split(after)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [Line] = [], a = 0, b = 0
        while a < old.count || b < new.count {
            if a < old.count && removed.contains(a) { lines.append(Line(kind: .removed, old: a + 1, text: old[a].text, noNewline: old[a].open)); a += 1 }
            else if b < new.count && inserted.contains(b) { lines.append(Line(kind: .added, new: b + 1, text: new[b].text, noNewline: new[b].open)); b += 1 }
            else if a < old.count && b < new.count { lines.append(Line(kind: .context, old: a + 1, new: b + 1, text: new[b].text, noNewline: new[b].open)); a += 1; b += 1 }
            else if a < old.count { lines.append(Line(kind: .removed, old: a + 1, text: old[a].text, noNewline: old[a].open)); a += 1 }
            else { lines.append(Line(kind: .added, new: b + 1, text: new[b].text, noNewline: new[b].open)); b += 1 }
        }
        markWords(in: &lines)
        // Changes closer than twice the context share a hunk, as in Git.
        var groups: [ClosedRange<Int>] = []
        for index in lines.indices where lines[index].kind != .context {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = groups.last, range.lowerBound <= last.upperBound + 1 { groups[groups.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound) }
            else { groups.append(range) }
        }
        return groups.map { range in
            let slice = Array(lines[range])
            let olds = slice.compactMap(\.old), news = slice.compactMap(\.new)
            // A side with no lines starts at the line before the hunk, as in Git.
            let oldBefore = lines[..<range.lowerBound].last { $0.old != nil }?.old ?? 0
            let newBefore = lines[..<range.lowerBound].last { $0.new != nil }?.new ?? 0
            return Hunk(oldStart: olds.first ?? oldBefore, oldCount: olds.count, newStart: news.first ?? newBefore, newCount: news.count, lines: slice)
        }
    }

    /// A patch `git apply` accepts from the repository root.
    public static func patch(before: String, after: String, path: String) -> String {
        let hunks = hunks(before: before, after: after)
        guard !hunks.isEmpty else { return "" }
        var output = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n"
        for hunk in hunks {
            output += hunk.header + "\n"
            for line in hunk.lines {
                output += (line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text + "\n"
                if line.noNewline { output += "\\ No newline at end of file\n" }
            }
        }
        return output
    }

    /// Pairs each run of removed lines with the added lines after it and marks the words that differ,
    /// so one edited word in a long Markdown paragraph is easy to spot.
    private static func markWords(in lines: inout [Line]) {
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            var added = index
            while added < lines.count && lines[added].kind == .removed { added += 1 }
            var end = added
            while end < lines.count && lines[end].kind == .added { end += 1 }
            for offset in 0..<min(added - index, end - added) {
                if let spans = wordSpans(old: lines[index + offset].text, new: lines[added + offset].text) {
                    lines[index + offset].spans = spans.old; lines[added + offset].spans = spans.new
                }
            }
            index = end
        }
    }

    /// Nil when the lines share too little for word marks to help; the whole line then reads as replaced.
    static func wordSpans(old: String, new: String) -> (old: [Span], new: [Span])? {
        let a = words(old), b = words(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        func isSpace(_ word: Substring) -> Bool { word.allSatisfy(\.isWhitespace) }
        let kept = a.indices.filter { !removed.contains($0) && !isSpace(a[$0]) }.count
        let total = a.filter { !isSpace($0) }.count + b.filter { !isSpace($0) }.count
        guard total > 0, Double(kept * 2) / Double(total) >= 0.4 else { return nil }
        return (spans(a, changed: removed), spans(b, changed: inserted))
    }

    /// Letters and digits group into words, whitespace into runs, and each other character stands alone.
    static func words(_ text: String) -> [Substring] {
        var result: [Substring] = [], start = text.startIndex, previous: Int?
        for index in text.indices {
            let character = text[index]
            let kind = character.isLetter || character.isNumber || character == "_" ? 0 : character.isWhitespace ? 1 : 2
            if let previous, kind != previous || kind == 2 { result.append(text[start..<index]); start = index }
            previous = kind
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    private static func spans(_ words: [Substring], changed: Set<Int>) -> [Span] {
        var flags = words.indices.map { changed.contains($0) }
        // A space between two changed words joins them into one mark.
        for index in flags.indices.dropFirst().dropLast() where !flags[index] && words[index].allSatisfy(\.isWhitespace) && flags[index - 1] && flags[index + 1] {
            flags[index] = true
        }
        var result: [Span] = []
        for (word, flag) in zip(words, flags) {
            if result.last?.changed == flag { result[result.count - 1].text += word } else { result.append(Span(text: String(word), changed: flag)) }
        }
        return result
    }
}

/// Places a model's find/replace changes in a file's text. Each find must match exactly one place: exactly, or
/// allowing for the ways models misquote (trailing spaces, blank lines, an added list marker). A change that
/// can't be placed is reported, never guessed.
public enum TextPatch {
    public struct Change: Hashable, Sendable {
        public var find: String
        public var replace: String
        public var why: String
        public init(find: String, replace: String, why: String) { self.find = find; self.replace = replace; self.why = why }
    }

    public struct Unplaced: Hashable, Sendable {
        public var change: Change
        public var reason: String
    }

    public struct Result: Sendable {
        public var text: String
        public var notes: [ChangeNote]
        public var unplaced: [Unplaced]
    }

    /// Where a change goes, and its replacement when quoting it required adjusting.
    private enum Location { case found(Range<String.Index>, String?), missing, repeated }

    public static func apply(_ changes: [Change], to text: String) -> Result {
        var placed: [(range: Range<String.Index>, change: Change)] = [], appended: [Change] = [], unplaced: [Unplaced] = []
        var seen = Set<[String]>()
        for change in changes where change.find != change.replace {
            // The same edit twice is one edit, not a conflict.
            guard seen.insert([change.find, change.replace]).inserted else { continue }
            if change.find.isEmpty { appended.append(change); continue }
            switch locate(change.find, replace: change.replace, in: text) {
            case .found(let range, let adjusted):
                var change = change
                if let adjusted { change.replace = adjusted }
                if placed.contains(where: { $0.range.overlaps(range) }) { unplaced.append(Unplaced(change: change, reason: "it overlaps another change")) }
                else { placed.append((range, change)) }
            case .missing: unplaced.append(Unplaced(change: change, reason: "its text is not in the file"))
            case .repeated: unplaced.append(Unplaced(change: change, reason: "its text appears more than once"))
            }
        }
        placed.sort { $0.range.lowerBound < $1.range.lowerBound }
        var output = "", cursor = text.startIndex, line = 1, notes: [ChangeNote] = []
        for (range, change) in placed {
            let kept = text[cursor..<range.lowerBound]
            output += kept; line += newlines(in: kept)
            notes.append(ChangeNote(line: line + sharedLeadingLines(change.find, change.replace), text: change.why))
            output += change.replace; line += newlines(in: change.replace)
            cursor = range.upperBound
        }
        output += text[cursor...]
        for change in appended {
            if !output.isEmpty && output.utf8.last != 0x0A { output += "\n" }
            notes.append(ChangeNote(line: newlines(in: output) + 1, text: change.why))
            output += change.replace
        }
        return Result(text: output, notes: notes, unplaced: unplaced)
    }

    private static func locate(_ find: String, replace: String, in text: String) -> Location {
        switch exactly(find, in: text) {
        case .missing: break
        case let location: return location
        }
        switch byLines(find, in: text) {
        case .missing: break
        case let location: return location
        }
        // A sentence quoted from the middle of a bullet sometimes gets a list marker of its own.
        if !find.contains(where: \.isNewline), let marker = find.range(of: #"^\s*(?:[-*+>]|\d+[.)])\s+"#, options: .regularExpression),
           case .found(let range, _) = exactly(String(find[marker.upperBound...]), in: text) {
            let prefix = String(find[marker])
            return .found(range, replace.hasPrefix(prefix) ? String(replace.dropFirst(prefix.count)) : replace)
        }
        // A reply escaped twice spells line breaks as a backslash and an n.
        if find.contains("\\n"), !find.contains(where: \.isNewline) {
            func unescaped(_ text: String) -> String {
                text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\\"", with: "\"")
            }
            if case .found(let range, let adjusted) = locate(unescaped(find), replace: unescaped(replace), in: text) { return .found(range, adjusted ?? unescaped(replace)) }
            return .missing
        }
        return byListContent(find, replace: replace, in: text)
    }

    /// The last resort, for quotes that renumber a list item, drop its marker, or lose indentation: lines compared
    /// by their text alone. The replacement gets the file's markers and indentation back where it only repeated the misquote.
    private static func byListContent(_ find: String, replace: String, in text: String) -> Location {
        func parts(_ line: Substring) -> (prefix: Substring, content: Substring) {
            var content = line
            while let last = content.last, last == " " || last == "\t" { content.removeLast() }
            guard let marker = content.range(of: #"^[ \t]*(?:(?:[-*+>]|\d+[.)])[ \t]+)?"#, options: .regularExpression) else { return ("", content) }
            return (content[marker], content[marker.upperBound...])
        }
        let needle = find.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(parts).filter { !$0.content.isEmpty }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let content = lines.indices.filter { !parts(lines[$0]).content.isEmpty }
        guard !needle.isEmpty, content.count >= needle.count else { return .missing }
        var start: Int?
        for candidate in 0...(content.count - needle.count) where needle.indices.allSatisfy({ parts(lines[content[candidate + $0]]).content == needle[$0].content }) {
            guard start == nil else { return .repeated }
            start = candidate
        }
        guard let start else { return .missing }
        var range = lines[content[start]].startIndex..<lines[content[start + needle.count - 1]].endIndex
        if find.last?.isNewline == true, range.upperBound < text.endIndex, text[range.upperBound].isNewline { range = range.lowerBound..<text.index(after: range.upperBound) }
        // Replacement lines follow the quoted lines in order; restore the file's prefix where the model kept its own wrong one.
        var output: [String] = [], index = 0
        for line in replace.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let (prefix, body) = parts(line)
            if !body.isEmpty, index < needle.count {
                let actual = parts(lines[content[start + index]]).prefix
                output.append(prefix == needle[index].prefix && prefix != actual ? String(actual) + String(line.dropFirst(prefix.count)) : String(line))
                index += 1
            } else { output.append(String(line)) }
        }
        return .found(range, output.joined(separator: "\n"))
    }

    private static func exactly(_ find: String, in text: String) -> Location {
        guard let first = text.range(of: find, options: .literal) else { return .missing }
        let rest = text.index(after: first.lowerBound)..<text.endIndex
        return text.range(of: find, options: .literal, range: rest) == nil ? .found(first, nil) : .repeated
    }

    /// Whole lines compared without trailing spaces and without blank lines, which models often drop or add between paragraphs.
    private static func byLines(_ find: String, in text: String) -> Location {
        func trimmed(_ line: Substring) -> Substring {
            var line = line
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return line
        }
        let needle = find.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(trimmed).filter { !$0.isEmpty }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let content = lines.indices.filter { !trimmed(lines[$0]).isEmpty }
        guard !needle.isEmpty, content.count >= needle.count else { return .missing }
        var found: Range<String.Index>?
        for start in 0...(content.count - needle.count) where needle.indices.allSatisfy({ trimmed(lines[content[start + $0]]) == needle[$0] }) {
            guard found == nil else { return .repeated }
            found = lines[content[start]].startIndex..<lines[content[start + needle.count - 1]].endIndex
        }
        // A find that ended with a line break replaces that break too, so the replacement's own break doesn't double it.
        if var range = found, find.last?.isNewline == true, range.upperBound < text.endIndex, text[range.upperBound].isNewline {
            range = range.lowerBound..<text.index(after: range.upperBound)
            found = range
        }
        return found.map { .found($0, nil) } ?? .missing
    }

    private static func newlines(in text: some StringProtocol) -> Int { text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }

    /// Lines a replacement repeats from the start of its find, so a note points at the first line that changes.
    private static func sharedLeadingLines(_ find: String, _ replace: String) -> Int {
        let a = find.utf8.split(separator: 0x0A, omittingEmptySubsequences: false), b = replace.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        var count = 0
        while count < min(a.count, b.count) - 1 && a[count].elementsEqual(b[count]) { count += 1 }
        return count
    }
}
