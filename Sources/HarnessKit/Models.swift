import Foundation
import CryptoKit
import Darwin

/// Foundation intentionally preserves /var aliases on macOS; descriptor-based traversal needs realpath.
public func physicalURL(_ url: URL) -> URL {
    guard let pointer = realpath(url.path, nil) else { return url }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: url.hasDirectoryPath)
}

/// Apps launched by launchd start with a 256 descriptor soft limit, which per-file watchers exhaust quickly.
@discardableResult
public func raiseOpenFileLimit(to target: rlim_t = 10_240) -> rlim_t {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
        NSLog("harnessmd: Could not read the open file limit (errno %d)", errno)
        return 0
    }
    let wanted = min(target, limit.rlim_max)
    guard limit.rlim_cur < wanted else { return limit.rlim_cur }
    var raised = limit; raised.rlim_cur = wanted
    guard setrlimit(RLIMIT_NOFILE, &raised) == 0 else {
        NSLog("harnessmd: Could not raise the open file limit to %llu (errno %d)", UInt64(wanted), errno)
        return limit.rlim_cur
    }
    return wanted
}

public enum HarnessError: LocalizedError, Equatable {
    case unsafePath(String), blocked(String), invalid(String), conflict, missingBlob, process(String), unstorableCurrent(String)
    /// Content that looks like a credential, with where and why, never the value.
    case sensitive(path: String, line: Int, reason: String)
    /// The model proposed changes, but none of them matched the file text.
    case unplaced(Int)
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "Unsafe or symbolic-link path: \(path)"
        case .blocked(let path): "Collection blocked by the privacy policy: \(path)"
        case .invalid(let message): message
        case .conflict: "The file changed since this proposal was prepared. Scan again and generate a new proposal."
        case .missingBlob: "The stored snapshot is missing or corrupt. No files were changed."
        case .process(let message): message
        case .unstorableCurrent(let reason): "The current content can't be kept as a safety snapshot (\(reason)). Restoring would overwrite it without one."
        case .sensitive(let path, let line, let reason): "Blocked by the privacy check: \(path) line \(line) looks like \(reason). Use a placeholder such as your_token or a reference such as $TOKEN instead."
        case .unplaced(let count): "The model's \(count == 1 ? "change" : "\(count) changes") didn't match the file text in two tries, so there is nothing to review. Run it again, or choose Thorough."
        }
    }
}

public struct Source: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var root: String
    public var name: String
    public var repositoryRoot: String?
    public var isPrivate: Bool
    public var enabled: Bool
    public var lastScan: Date?
    public var isWorktree: Bool { repositoryRoot != nil && repositoryRoot != root }
    public var isGlobal: Bool { kind != "repo" }
    /// Worktrees of one repository share a family, so their identical files are not duplication.
    public var family: String { repositoryRoot ?? root }
    public init(root: String, kind: String = "repo", name: String? = nil, repositoryRoot: String? = nil) {
        self.id = digest(Data((kind + ":" + root).utf8))
        self.kind = kind; self.root = root
        self.name = name ?? URL(fileURLWithPath: root).lastPathComponent
        self.repositoryRoot = repositoryRoot
        self.isPrivate = false; self.enabled = true
    }
}

public struct TrackedFile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sourceID: String
    public var path: String
    public var category: String
    public var tool: String
    public var isDirectory: Bool
    public var blob: String?
    public var lastSeen: Date
    /// Tool configs and generated memories stay local: never sent to a model, never edited by a proposal.
    public var allowsAI: Bool { !["config", "memories"].contains(category) }
    public init(sourceID: String, path: String, category: String, tool: String, isDirectory: Bool = false) {
        id = digest(Data((sourceID + ":" + path).utf8))
        self.sourceID = sourceID; self.path = path; self.category = category; self.tool = tool
        self.isDirectory = isDirectory; self.blob = nil; self.lastSeen = Date()
    }
}

public struct Version: Codable, Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var fileID: String
    public var blob: String?
    public var capturedAt: Date = Date()
    public var origin: String
    public var note: String
}

/// A deterministic directory manifest. Single files use the empty string as their entry name.
public struct Snapshot: Codable, Equatable, Sendable {
    public var entries: [String: Data]
    public var executablePaths: [String]
    public init(entries: [String: Data], executablePaths: [String] = []) {
        self.entries = entries; self.executablePaths = executablePaths.sorted()
    }
    private enum CodingKeys: String, CodingKey { case entries, executablePaths }
    /// Decodes the v0.1 blob format, which embedded every entry in one JSON document.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([String: Data].self, forKey: .entries)
        executablePaths = try values.decodeIfPresent([String].self, forKey: .executablePaths)?.sorted() ?? []
    }
    public static func text(_ text: String) -> Snapshot { Snapshot(entries: ["": Data(text.utf8)]) }
    public var manifest: Manifest {
        Manifest(entries: entries.mapValues(digest), executablePaths: Array(Set(executablePaths)).sorted())
    }
    /// The content address of this snapshot, used as version, file, and proposal base identity.
    public func identity() throws -> String { digest(try manifest.encoded()) }
    public var displayText: String {
        func text(_ data: Data) -> String {
            Privacy.isText(data) ? String(decoding: data, as: UTF8.self) : "(binary file, \(data.count.formatted()) bytes)"
        }
        if let data = entries[""] { return text(data) }
        return entries.keys.sorted().map { "## \($0)\n" + text(entries[$0]!) }.joined(separator: "\n\n")
    }
}

/// Entry names mapped to content hashes; contents are stored once each under `blobs/`.
public struct Manifest: Codable, Equatable, Sendable {
    public var entries: [String: String]
    public var executablePaths: [String]
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Why the model made one change, anchored to the line in the new content where the change starts.
public struct ChangeNote: Codable, Hashable, Sendable {
    public var line: Int
    public var text: String
    public init(line: Int, text: String) { self.line = line; self.text = text }
}

public struct ProposalEdit: Codable, Hashable, Sendable {
    public var fileID: String
    public var baseBlob: String
    public var content: String
    /// One note per change, shown on the diff next to it.
    public var notes: [ChangeNote]
    public init(fileID: String, baseBlob: String, content: String, notes: [ChangeNote] = []) {
        self.fileID = fileID; self.baseBlob = baseBlob; self.content = content; self.notes = notes
    }
    private enum CodingKeys: String, CodingKey { case fileID, baseBlob, content, notes }
    /// Edits from before changes carried notes were whole-file replacements.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try values.decode(String.self, forKey: .fileID)
        baseBlob = try values.decode(String.self, forKey: .baseBlob)
        content = try values.decode(String.self, forKey: .content)
        notes = try values.decodeIfPresent([ChangeNote].self, forKey: .notes) ?? []
    }
}

public struct Proposal: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID().uuidString
    public var createdAt = Date()
    /// pending, accepted, rejected, expired, kept (rejected as fine, and remembered for future requests),
    /// or replaced (a newer proposal for the same file arrived).
    public var status = "pending"
    public var model: String
    /// The model's summary of its changes, in Markdown.
    public var rationale: String
    public var edits: [ProposalEdit]
    public var note: String
    /// The task the user gave the model for this request.
    public var instructions = ""
    /// Every file the request analyzed, including ones it left unchanged.
    public var fileIDs: [String] = []
    public init(model: String, rationale: String, edits: [ProposalEdit], note: String, instructions: String = "", fileIDs: [String] = []) {
        self.model = model; self.rationale = rationale; self.edits = edits; self.note = note; self.instructions = instructions; self.fileIDs = fileIDs
    }
    private enum CodingKeys: String, CodingKey { case id, createdAt, status, model, rationale, edits, note, instructions, fileIDs }
    /// v0.1 payloads predate `instructions` and `fileIDs`.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        status = try values.decode(String.self, forKey: .status)
        model = try values.decode(String.self, forKey: .model)
        rationale = try values.decode(String.self, forKey: .rationale)
        edits = try values.decode([ProposalEdit].self, forKey: .edits)
        note = try values.decode(String.self, forKey: .note)
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        fileIDs = try values.decodeIfPresent([String].self, forKey: .fileIDs) ?? []
    }
}

public struct AIInvocation: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var date = Date()
    public var backend: String
    public var model: String
    public var fileIDs: [String]
    public var status: String
}

public struct Inventory: Sendable {
    public var sources: [Source] = []
    public var files: [TrackedFile] = []
    /// Newest first, bounded by `Store.recentVersionLimit`; a file's full history comes from `Store.versions(fileID:)`.
    public var versions: [Version] = []
    /// Like `versions`, without first captures: what actually changed.
    public var changes: [Version] = []
    /// Whether each repository file (by file ID) is added to Git. Global files and unreadable indexes are absent.
    public var gitTracked: [String: Bool] = [:]
    public var versionCounts: [String: Int] = [:]
    public var changesToday = 0
    public var proposals: [Proposal] = []
    public var invocations: [AIInvocation] = []
    /// Keys of findings marked "It's fine".
    public var dismissed: Set<String> = []
    public init() {}
}

/// What a backend was last set to, so switching backends keeps each one's path, model, and effort.
public struct BackendChoice: Codable, Equatable, Sendable {
    public var binary: String
    public var model: String
    public var effort: String
    public init(binary: String, model: String, effort: String) { self.binary = binary; self.model = model; self.effort = effort }
}

public struct AppSettings: Codable, Sendable {
    public var roots: [String] = []
    /// Extra instruction files to collect in repositories: names (`GEMINI.md`) or path globs (`.kilocode/rules/*.md`).
    public var customPatterns: [String] = []
    public var includeGlobals = false
    public var sweepSeconds: Double = 3600
    public var paused = false
    public var backend = "claude"
    public var binary = "/opt/homebrew/bin/claude"
    public var model = ""
    /// Reasoning effort in the backend's own terms; empty uses its default.
    public var effort = ""
    public var timeout: Double = 120
    public var ollamaURL = "http://127.0.0.1:11434"
    /// The default task for AI analysis; empty uses `AIService.defaultInstructions`.
    public var analysisInstructions = ""
    /// Off runs quick analysis, without extended thinking; on uses `effort`.
    public var thoroughAnalysis = false
    public var backendChoices: [String: BackendChoice] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case roots, customPatterns, includeGlobals, sweepSeconds, paused, backend, binary, model, effort, timeout, ollamaURL, analysisInstructions, thoroughAnalysis, backendChoices
    }
    /// Missing keys keep their defaults, so settings written by other versions still load.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self), defaults = AppSettings()
        roots = try values.decodeIfPresent([String].self, forKey: .roots) ?? defaults.roots
        customPatterns = try values.decodeIfPresent([String].self, forKey: .customPatterns) ?? defaults.customPatterns
        includeGlobals = try values.decodeIfPresent(Bool.self, forKey: .includeGlobals) ?? defaults.includeGlobals
        sweepSeconds = try values.decodeIfPresent(Double.self, forKey: .sweepSeconds) ?? defaults.sweepSeconds
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused
        backend = try values.decodeIfPresent(String.self, forKey: .backend) ?? defaults.backend
        binary = try values.decodeIfPresent(String.self, forKey: .binary) ?? defaults.binary
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        effort = try values.decodeIfPresent(String.self, forKey: .effort) ?? defaults.effort
        timeout = try values.decodeIfPresent(Double.self, forKey: .timeout) ?? defaults.timeout
        ollamaURL = try values.decodeIfPresent(String.self, forKey: .ollamaURL) ?? defaults.ollamaURL
        analysisInstructions = try values.decodeIfPresent(String.self, forKey: .analysisInstructions) ?? defaults.analysisInstructions
        thoroughAnalysis = try values.decodeIfPresent(Bool.self, forKey: .thoroughAnalysis) ?? defaults.thoroughAnalysis
        backendChoices = try values.decodeIfPresent([String: BackendChoice].self, forKey: .backendChoices) ?? defaults.backendChoices
    }
    public func permits(_ source: Source) -> Bool {
        if source.isGlobal { return includeGlobals }
        return roots.contains { source.root == $0 || source.root.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

/// Indices of items connected through shared file IDs, each group in item order, groups in order of their first item.
public func connectedGroups(_ fileSets: [[String]]) -> [[Int]] {
    var parent = Array(fileSets.indices), owner: [String: Int] = [:]
    func root(_ index: Int) -> Int {
        var index = index
        while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
        return index
    }
    for (index, files) in fileSets.enumerated() {
        for file in files {
            if let other = owner[file] { parent[root(index)] = root(other) } else { owner[file] = index }
        }
    }
    var order: [Int] = [], members: [Int: [Int]] = [:]
    for index in fileSets.indices {
        let group = root(index)
        if members[group] == nil { order.append(group) }
        members[group, default: []].append(index)
    }
    return order.map { members[$0]! }
}

/// The row to select after a decision on the rows at `selected` (rows given by the item IDs they hold), as an
/// index into `after`: one selected row stays while it keeps an item; otherwise the first later row that still
/// exists, then the nearest earlier one. Rows can merge or split as items go, so a row is found by any item it held.
public func rowAfterDecision(before: [[String]], selected: Set<Int>, after: [[String]]) -> Int? {
    func find(_ row: [String]) -> Int? { after.firstIndex { !Set($0).isDisjoint(with: row) } }
    let positions = selected.sorted()
    if positions.count == 1, let same = find(before[positions[0]]) { return same }
    guard let last = positions.last, let first = positions.first else { return after.isEmpty ? nil : 0 }
    for row in before[(last + 1)...] { if let next = find(row) { return next } }
    for row in before[..<first].reversed() { if let previous = find(row) { return previous } }
    return nil
}

public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
