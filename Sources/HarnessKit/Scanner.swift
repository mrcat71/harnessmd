import Foundation
import Darwin

public struct ScanReport: Sendable {
    public var sources = 0
    public var files = 0
    public var warnings: [String] = []
    public init() {}
}

public struct Discovery: Sendable {
    public var sources: [Source] = []
    public var warnings: [String] = []
}

public struct Listing: Sendable {
    public var files: [TrackedFile] = []
    public var warnings: [String] = []
    /// Resolved directories of skills whose SKILL.md is a symlink. Links are never followed,
    /// so those skills are versioned only where they live.
    public var linkedSkills: [String] = []
}

public struct Scanner: Sendable {
    public static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", ".swiftpm", "vendor", "dist", "build", "target", ".next", ".venv", "venv", "__pycache__", ".terraform", ".tofu", "Pods", "DerivedData", ".idea"]
    /// Home-relative global locations. Only their per-tool maps are collected, never the caches,
    /// plugins, sessions, or worktrees the tools keep beside them.
    public static let globalLocations: [(path: String, name: String, kind: String)] = [
        (".claude", "Claude Code", "claude"), (".codex", "Codex", "codex"), (".agents", "Shared skills", "shared"),
        (".agent-skills", "Agent skills", "agent-skills"), (".config/opencode", "OpenCode", "opencode"),
    ]
    static let instructionNames = ["agents.md": "codex", "agents.override.md": "codex", "claude.md": "claude", "claude.local.md": "claude", "desu.md": "shared", ".cursorrules": "shared", ".windsurfrules": "shared"]
    static let toolDirectories = [".claude": "claude", ".codex": "codex", ".opencode": "opencode"]
    static let skillParents = [".claude": "claude", ".codex": "codex", ".agents": "shared", ".opencode": "opencode"]
    static let toolCategories = ["commands": "prompts", "command": "prompts", "prompts": "prompts", "agents": "agents", "agent": "agents", "rules": "rules", "output-styles": "prompts"]

    struct GlobalDirectory: Sendable {
        var path: String
        /// File extension to category.
        var categories: [String: String]
        var recursive = true
    }
    struct GlobalMap: Sendable {
        var tool: String
        /// Top-level file name to category.
        var files: [String: String] = [:]
        var directories: [GlobalDirectory] = []
        /// Folders whose child directories are skills; the empty string is the location itself.
        var skills: [String] = []
    }
    static let globalMaps: [String: GlobalMap] = [
        "claude": GlobalMap(tool: "claude", files: ["CLAUDE.md": "instructions", "settings.json": "config"], directories: [
            GlobalDirectory(path: "commands", categories: ["md": "prompts"]), GlobalDirectory(path: "agents", categories: ["md": "agents"]),
            GlobalDirectory(path: "rules", categories: ["md": "rules"]), GlobalDirectory(path: "output-styles", categories: ["md": "prompts"]),
        ], skills: ["skills"]),
        "codex": GlobalMap(tool: "codex", files: ["AGENTS.md": "instructions", "AGENTS.override.md": "instructions", "config.toml": "config"], directories: [
            GlobalDirectory(path: "prompts", categories: ["md": "prompts"]),
            GlobalDirectory(path: "memories", categories: ["md": "memories"], recursive: false),
            GlobalDirectory(path: "rules", categories: ["rules": "config"]),
            GlobalDirectory(path: "agents", categories: ["toml": "config", "md": "agents"]),
        ], skills: ["skills"]),
        "shared": GlobalMap(tool: "shared", skills: ["skills"]),
        "agent-skills": GlobalMap(tool: "shared", skills: [""]),
        "opencode": GlobalMap(tool: "opencode", files: ["AGENTS.md": "instructions", "opencode.json": "config", "opencode.jsonc": "config"], directories: [
            GlobalDirectory(path: "agent", categories: ["md": "agents"]), GlobalDirectory(path: "agents", categories: ["md": "agents"]),
            GlobalDirectory(path: "command", categories: ["md": "prompts"]), GlobalDirectory(path: "commands", categories: ["md": "prompts"]),
        ], skills: ["skills", "skill"]),
    ]

    /// User-added instruction files: a pattern without `/` matches file names, one with `/` matches paths.
    private let customNames: [NSRegularExpression]
    private let customPaths: [NSRegularExpression]

    /// Explicit, so `Scanner()` keeps resolving here rather than to Foundation's `Scanner`.
    public init() { self.init(customPatterns: []) }

    public init(customPatterns: [String]) {
        var names: [NSRegularExpression] = [], paths: [NSRegularExpression] = []
        for pattern in customPatterns {
            guard let regex = Self.globRegex(pattern) else {
                NSLog("harnessmd: Ignoring invalid instruction file pattern %@", pattern)
                continue
            }
            if pattern.contains("/") { paths.append(regex) } else { names.append(regex) }
        }
        customNames = names; customPaths = paths
    }

    /// A pattern a user can type: `*` within a name, `**` across folders, `?` for one character. Case-insensitive, like the file system.
    public static func globRegex(_ pattern: String) -> NSRegularExpression? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200, !trimmed.hasPrefix("/"), !trimmed.split(separator: "/").contains("..") else { return nil }
        var regex = "^", rest = Substring(trimmed)
        while let character = rest.first {
            if rest.hasPrefix("**/") { regex += "(?:[^/]+/)*"; rest = rest.dropFirst(3) }
            else if rest.hasPrefix("**") { regex += ".*"; rest = rest.dropFirst(2) }
            else if character == "*" { regex += "[^/]*"; rest = rest.dropFirst() }
            else if character == "?" { regex += "[^/]"; rest = rest.dropFirst() }
            else { regex += NSRegularExpression.escapedPattern(for: String(character)); rest = rest.dropFirst() }
        }
        return try? NSRegularExpression(pattern: regex + "$", options: [.caseInsensitive])
    }

    private func matchesCustom(_ path: String, name: String) -> Bool {
        func matches(_ regex: NSRegularExpression, _ text: String) -> Bool { regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        return customNames.contains { matches($0, name) } || customPaths.contains { matches($0, path) }
    }

    public func discover(roots: [String], globals: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Discovery {
        var found: [String: Source] = [:]
        var warnings: [String] = []
        for root in roots {
            let url = URL(fileURLWithPath: root)
            guard url.path == physicalURL(url).path else { throw HarnessError.unsafePath(root) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HarnessError.invalid("Scan root is unavailable: \(root)")
            }
            if let source = try repository(at: url) { found[source.id] = source }
            warnings += try walk(url) { candidate, values, iterator in
                guard values.isDirectory == true else { return }
                if let source = try repository(at: candidate) { found[source.id] = source }
                if Self.skippedDirectories.contains(candidate.lastPathComponent) { iterator.skipDescendants() }
            }
        }
        if globals {
            for location in Self.globalLocations {
                let url = physicalURL(home.appendingPathComponent(location.path))
                guard isDirectory(url) else { continue }
                let source = Source(root: url.path, kind: location.kind, name: location.name)
                found[source.id] = source
            }
        }
        return Discovery(sources: found.values.sorted { $0.root < $1.root }, warnings: warnings)
    }

    private func repository(at url: URL) throws -> Source? {
        let git = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: git.path) else { return nil }
        let values = try git.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { return nil }
        var canonical = url.path
        if values.isDirectory != true, let data = try SafeFiles.read(root: url.path, path: ".git"),
           let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") {
            let gitdir = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let path = URL(fileURLWithPath: gitdir, relativeTo: url).standardizedFileURL.path
            if let range = path.range(of: "/.git/worktrees/") { canonical = String(path[..<range.lowerBound]) }
        }
        return Source(root: url.path, repositoryRoot: canonical)
    }

    public func listing(of source: Source) throws -> Listing {
        let base = URL(fileURLWithPath: source.root)
        guard physicalURL(base).path == base.path else { throw HarnessError.unsafePath(source.root) }
        var listing = source.isGlobal ? try globalListing(base, source: source) : try repositoryListing(base, source: source)
        listing.files.sort { $0.path < $1.path }
        return listing
    }

    public func files(in source: Source) throws -> [TrackedFile] { try listing(of: source).files }

    /// Whether a known unit still falls under the collection policy. Units outside it keep their
    /// history but are no longer rechecked, so a narrower policy never records false deletions.
    public func stillCollected(_ file: TrackedFile, in source: Source) -> Bool {
        let parts = file.path.split(separator: "/").map(String.init)
        if source.isGlobal {
            guard let map = Self.globalMaps[source.kind] else { return false }
            if file.isDirectory { return map.skills.contains(parts.dropLast().joined(separator: "/")) }
            if parts.count == 1 { return map.files[file.path] != nil }
            return map.directories.contains { directory in
                parts.first == directory.path && (directory.recursive || parts.count == 2)
                    && directory.categories[URL(fileURLWithPath: file.path).pathExtension] != nil
            }
        }
        var ancestor = URL(fileURLWithPath: source.root)
        for part in parts.dropLast() {
            ancestor.appendPathComponent(part)
            if Self.skippedDirectories.contains(part) || hasGitMarker(ancestor) { return false }
        }
        return file.isDirectory ? repositorySkillTool(file.path) != nil : classifyRepositoryFile(file.path) != nil
    }

    private func repositoryListing(_ base: URL, source: Source) throws -> Listing {
        var files: [TrackedFile] = [], linked: [String] = []
        let warnings = try walk(base) { url, values, iterator in
            let relative = String(url.path.dropFirst(base.path.count + 1))
            if values.isDirectory == true {
                // Nested repositories and worktrees are sources of their own.
                if Self.skippedDirectories.contains(url.lastPathComponent) || Privacy.denied(relative) || hasGitMarker(url) {
                    iterator.skipDescendants(); return
                }
                guard let tool = repositorySkillTool(relative) else { return }
                switch skillMarker(url) {
                case .file:
                    files.append(TrackedFile(sourceID: source.id, path: relative, category: "skills", tool: tool, isDirectory: true))
                    iterator.skipDescendants()
                case .link(let target): linked.append(target); iterator.skipDescendants()
                case .none: break
                }
                return
            }
            guard values.isRegularFile == true, !Privacy.denied(relative), let match = classifyRepositoryFile(relative) else { return }
            files.append(TrackedFile(sourceID: source.id, path: relative, category: match.category, tool: match.tool))
        }
        return Listing(files: files, warnings: warnings, linkedSkills: linked)
    }

    private func globalListing(_ base: URL, source: Source) throws -> Listing {
        guard let map = Self.globalMaps[source.kind] else { return Listing() }
        var listing = Listing()
        for (name, category) in map.files where isRegularFile(base.appendingPathComponent(name)) && !Privacy.denied(name) {
            listing.files.append(TrackedFile(sourceID: source.id, path: name, category: category, tool: map.tool))
        }
        for directory in map.directories {
            let url = base.appendingPathComponent(directory.path)
            guard isDirectory(url) else { continue }
            var files: [TrackedFile] = []
            let warnings = try walk(url) { child, values, iterator in
                let relative = directory.path + "/" + String(child.path.dropFirst(url.path.count + 1))
                if values.isDirectory == true {
                    if !directory.recursive || Self.skippedDirectories.contains(child.lastPathComponent) || Privacy.denied(relative) { iterator.skipDescendants() }
                    return
                }
                guard values.isRegularFile == true, !Privacy.denied(relative), let category = directory.categories[child.pathExtension] else { return }
                files.append(TrackedFile(sourceID: source.id, path: relative, category: category, tool: map.tool))
            }
            listing.files += files; listing.warnings += warnings
        }
        for folder in map.skills {
            let url = folder.isEmpty ? base : base.appendingPathComponent(folder)
            guard isDirectory(url) else { continue }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch { listing.warnings.append("Skipped unreadable \(url.path): \(error.localizedDescription)"); continue }
            for child in children where isDirectory(child) {
                let relative = (folder.isEmpty ? "" : folder + "/") + child.lastPathComponent
                guard !Privacy.denied(relative) else { continue }
                switch skillMarker(child) {
                case .file: listing.files.append(TrackedFile(sourceID: source.id, path: relative, category: "skills", tool: map.tool, isDirectory: true))
                case .link(let target): listing.linkedSkills.append(target)
                case .none: break
                }
            }
        }
        return listing
    }

    private enum SkillMarker { case file, link(String), none }

    /// SKILL.md must be a regular file; a symlinked one is reported by its resolved directory.
    private func skillMarker(_ directory: URL) -> SkillMarker {
        let marker = directory.appendingPathComponent("SKILL.md")
        let type = fileType(marker)
        if type == S_IFREG { return .file }
        if type == S_IFLNK { return .link(physicalURL(marker).deletingLastPathComponent().path) }
        return .none
    }

    private func repositorySkillTool(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, ["skills", "skill"].contains(parts[parts.count - 2]), let tool = Self.skillParents[parts[parts.count - 3]] else { return nil }
        // Only OpenCode accepts the singular folder name.
        return parts[parts.count - 2] == "skills" || tool == "opencode" ? tool : nil
    }

    private func classifyRepositoryFile(_ path: String) -> (category: String, tool: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        if let tool = Self.instructionNames[name.lowercased()] { return ("instructions", tool) }
        if parts.contains(".cursor"), parts.contains("rules"), name.hasSuffix(".mdc") { return ("rules", "shared") }
        if parts.count >= 2, parts[parts.count - 2] == ".github", name == "copilot-instructions.md" { return ("instructions", "shared") }
        if name == "opencode.json" || name == "opencode.jsonc" { return ("config", "opencode") }
        if name == ".mcp.json" { return ("config", "claude") }
        if matchesCustom(path, name: name) { return ("instructions", "shared") }
        guard let index = parts.lastIndex(where: { Self.toolDirectories[$0] != nil }), let tool = Self.toolDirectories[parts[index]] else { return nil }
        let scoped = Array(parts.dropFirst(index + 1))
        if scoped.count == 1 {
            return (tool == "claude" && name == "settings.json") || (tool == "codex" && name == "config.toml") ? ("config", tool) : nil
        }
        guard let first = scoped.first, let category = Self.toolCategories[first] else { return nil }
        switch URL(fileURLWithPath: name).pathExtension {
        case "md": return (category, tool)
        // Exec policies and TOML agent definitions are configuration: versioned, never sent to or edited by AI.
        case "rules", "toml": return ("config", tool)
        default: return nil
        }
    }

    private func fileType(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }
    private func isDirectory(_ url: URL) -> Bool { fileType(url) == S_IFDIR }
    private func isRegularFile(_ url: URL) -> Bool { fileType(url) == S_IFREG }
    private func hasGitMarker(_ url: URL) -> Bool {
        let type = fileType(url.appendingPathComponent(".git"))
        return type == S_IFDIR || type == S_IFREG
    }

    /// Visits entries below `base` without following links. Unreadable subdirectories are skipped
    /// with a warning; an unreadable base fails the walk, so callers never mistake it for empty.
    private func walk(_ base: URL, visit: (URL, URLResourceValues, FileManager.DirectoryEnumerator) throws -> Void) throws -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var warnings: [String] = []
        var baseFailure: Error?
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys), errorHandler: { url, error in
            if url.standardizedFileURL.path == base.standardizedFileURL.path { baseFailure = error; return false }
            warnings.append("Skipped unreadable \(url.path): \(error.localizedDescription)")
            return true
        }) else { throw HarnessError.invalid("Cannot enumerate \(base.path)") }
        for case let url as URL in iterator {
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: keys) }
            catch { warnings.append("Skipped \(url.path): \(error.localizedDescription)"); continue }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            try visit(url, values, iterator)
        }
        if let baseFailure { throw baseFailure }
        return warnings
    }
}
