import Foundation

public struct Finding: Identifiable, Hashable, Sendable {
    public var id: String
    /// `sync`: copies that should agree don't. `stale`: referenced paths are missing.
    public var kind: String
    public var title: String
    public var detail: String
    public var fileIDs: [String]
    /// What "It's fine" remembers: these files with this problem. A different problem in them shows again.
    public var key: String
    /// For missing paths: each path as written in the file.
    public var missing: [String] = []
}

public enum Analyzer {
    public static let driftThreshold = 0.6
    /// Per-tool renderings of one skill differ by a line or two; copies below this have diverged.
    public static let skillCopyThreshold = 0.9
    /// `registry.example.com`, `github.com`, `go.uber.org`: dotted labels ending in a letters-only top-level domain.
    private static func isHost(_ segment: String) -> Bool {
        let labels = segment.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !segment.hasPrefix("."), let top = labels.last, top.count >= 2, top.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }

    private static func folders(in root: String) -> [String] {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !Privacy.junkDirectories.contains($0.lastPathComponent) }
            .map(\.lastPathComponent).sorted()
    }

    private static func hasExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let suffix = name[name.index(after: dot)...]
        return (1...10).contains(suffix.count) && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static let pathReference = try! NSRegularExpression(pattern: #"`((?:\./)?(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+)`"#)
    private static let importReference = try! NSRegularExpression(pattern: #"(?:^|\s)@([^\s`'"()<>]+)"#)

    public static func similarity(_ left: String, _ right: String) -> Double { jaccard(fingerprint(left), fingerprint(right)) }

    /// Sorted, unique hashes of normalized five-word shingles.
    static func fingerprint(_ text: String) -> [UInt64] {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(stableHash)
        let width = min(5, words.count)
        guard width > 0 else { return [] }
        var shingles = Set<UInt64>()
        for start in 0...(words.count - width) {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for word in words[start..<(start + width)] { hash = (hash ^ word) &* 0x0000_0100_0000_01b3 }
            shingles.insert(hash)
        }
        return shingles.sorted()
    }

    private static func stableHash(_ word: Substring) -> UInt64 {
        word.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    static func jaccard(_ a: [UInt64], _ b: [UInt64]) -> Double {
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty ? 1 : 0 }
        var i = 0, j = 0, common = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { common += 1; i += 1; j += 1 } else if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return Double(common) / Double(a.count + b.count - common)
    }

    public static func analyze(_ inventory: Inventory, snapshots: [String: Snapshot]) -> [Finding] {
        let sources = Dictionary(inventory.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let files = inventory.files.filter { $0.blob != nil && snapshots[$0.id] != nil }
        let instructions = files.filter { $0.category == "instructions" }
        var texts: [String: String] = [:], prints: [String: [UInt64]] = [:]
        for file in instructions {
            let text = snapshots[file.id]!.displayText
            texts[file.id] = text; prints[file.id] = fingerprint(text)
        }
        var findings: [Finding] = []

        // AGENTS.md and CLAUDE.md side by side should agree, unless one imports the other.
        let neighbours = Dictionary(grouping: instructions.filter { ["agents.md", "claude.md"].contains(name(of: $0.path).lowercased()) },
                                    by: { $0.sourceID + "|" + parent(of: $0.path) })
        for (_, group) in neighbours.sorted(by: { $0.key < $1.key }) {
            guard let agents = group.first(where: { name(of: $0.path).lowercased() == "agents.md" }),
                  let claude = group.first(where: { name(of: $0.path).lowercased() == "claude.md" }) else { continue }
            if imports(texts[claude.id]!, from: claude.path, target: agents.path) || imports(texts[agents.id]!, from: agents.path, target: claude.path) { continue }
            let score = jaccard(prints[agents.id]!, prints[claude.id]!)
            guard score < driftThreshold else { continue }
            // The pair is the decision: if they are meant to differ, edits that keep them different don't bring it back.
            findings.append(Finding(id: "drift|\(agents.id)|\(claude.id)", kind: "sync", title: "AGENTS.md and CLAUDE.md disagree",
                                    detail: "\(agents.path) and \(claude.path) share \(Int(score * 100))% of their word shingles. Make one import the other, or align them.",
                                    fileIDs: [agents.id, claude.id], key: "drift|\(agents.id)|\(claude.id)"))
        }

        // One finding per file, listing every missing path, so a file with many references reads as one signal.
        var topFolders: [String: [String]] = [:]
        for file in instructions {
            guard let source = sources[file.sourceID], let text = texts[file.id] else { continue }
            let directory = parent(of: file.path)
            var checked = Set<String>(), missing: [String] = []
            for match in pathReference.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let path = String(text[range])
                guard !path.hasPrefix("../"), !path.contains("/../"), checked.insert(path).inserted else { continue }
                // Relative to the file, then the source root, then a top-level folder that commands run from (`playbooks/`).
                func exists(_ relative: String) -> Bool {
                    let near = directory.isEmpty ? [relative] : [directory + "/" + relative, relative]
                    if near.contains(where: { FileManager.default.fileExists(atPath: source.root + "/" + $0) }) { return true }
                    if topFolders[source.root] == nil { topFolders[source.root] = folders(in: source.root) }
                    return topFolders[source.root]!.contains { FileManager.default.fileExists(atPath: source.root + "/" + $0 + "/" + relative) }
                }
                if exists(path) { continue }
                // A missing first folder means a host (`registry.example.com/team/chart`) or, without a file name,
                // a slug such as `bitnami/redis` or `org/repo`: not a local path.
                let local = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
                let first = String(local.prefix { $0 != "/" })
                if !exists(first), isHost(first) || (!path.hasPrefix("./") && !hasExtension(name(of: local))) { continue }
                missing.append(path)
            }
            guard !missing.isEmpty else { continue }
            findings.append(Finding(id: "stale|\(file.id)", kind: "stale",
                                    title: missing.count == 1 ? "A referenced path is missing" : "\(missing.count) referenced paths are missing",
                                    detail: "\(file.path) references \(missing.joined(separator: ", ")).", fileIDs: [file.id],
                                    key: "stale|\(file.id)|" + missing.joined(separator: ","), missing: missing))
        }

        // Same-named skills matter when their SKILL.md copies diverge; synced or rendered copies are expected.
        for (skill, group) in Dictionary(grouping: files.filter(\.isDirectory), by: { name(of: $0.path) }).sorted(by: { $0.key < $1.key }) {
            // Worktrees of one repository carry the same skill at the same path; count it once.
            var locations: [String: TrackedFile] = [:]
            for unit in group.sorted(by: { $0.id < $1.id }) {
                let key = (sources[unit.sourceID]?.family ?? unit.sourceID) + "|" + unit.path
                if locations[key] == nil { locations[key] = unit }
            }
            let distinct = locations.values.sorted { $0.id < $1.id }
            let copies = distinct.compactMap { snapshots[$0.id]?.entries["SKILL.md"] }.map { fingerprint(String(decoding: $0, as: UTF8.self)) }
            guard distinct.count > 1, copies.count > 1 else { continue }
            var lowest = 1.0
            for i in copies.indices { for j in copies.indices where i < j { lowest = min(lowest, jaccard(copies[i], copies[j])) } }
            guard lowest < skillCopyThreshold else { continue }
            let places = distinct.map { (sources[$0.sourceID]?.name ?? "Source") + "/" + $0.path }.sorted()
            findings.append(Finding(id: "inventory|\(skill)", kind: "sync", title: "Copies of skill \(skill) differ",
                                    detail: "\(places.count) locations: \(places.joined(separator: ", ")). The least similar SKILL.md copies share \(Int(lowest * 100))% of their word shingles.",
                                    fileIDs: distinct.map(\.id), key: "inventory|\(skill)|" + places.joined(separator: ",")))
        }
        return findings
    }

    private static func name(of path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
    private static func parent(of path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }

    /// Claude Code `@path` imports, resolved relative to the importing file.
    private static func imports(_ text: String, from path: String, target: String) -> Bool {
        let base = URL(fileURLWithPath: "/" + parent(of: path), isDirectory: true)
        for match in importReference.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            var reference = String(text[range])
            while let last = reference.last, ".,;:".contains(last) { reference.removeLast() }
            guard !reference.isEmpty, !reference.hasPrefix("~"), !reference.hasPrefix("/") else { continue }
            if base.appendingPathComponent(reference).standardizedFileURL.path.lowercased() == ("/" + target).lowercased() { return true }
        }
        return false
    }
}
