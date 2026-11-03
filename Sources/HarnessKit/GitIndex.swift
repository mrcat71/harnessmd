import Foundation

/// Paths a repository has added to Git, read straight from its index file. No Git command runs, so
/// no repository configuration (hooks, fsmonitor) can execute anything.
public struct GitIndex: Sendable, Equatable {
    public var paths: Set<String>
    /// Sparse-index directory entries; everything below them is tracked.
    public var directories: [String]

    public func contains(_ path: String) -> Bool {
        paths.contains(path) || directories.contains { path.hasPrefix($0) }
    }

    /// The index file of a working tree, following the `.git` file of worktrees and submodules.
    public static func file(workingTree root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit.appendingPathComponent("index") }
        guard let data = try? Data(contentsOf: dotGit), data.count < 4096, let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
        let gitdir = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: gitdir, relativeTo: root).standardizedFileURL.appendingPathComponent("index")
    }

    /// Index versions 2 to 4 with SHA-1 or SHA-256 object names. Returns nil for anything else,
    /// including split indexes, rather than reporting tracked files as untracked.
    public static func parse(_ data: Data) -> GitIndex? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("DIRC".utf8) else { return nil }
        let version = word(bytes, 4), count = Int(word(bytes, 8))
        guard (2...4).contains(version) else { return nil }
        for idLength in [20, 32] {
            if let index = entries(bytes, version: version, count: count, idLength: idLength) { return index }
        }
        return nil
    }

    private static func entries(_ bytes: [UInt8], version: UInt32, count: Int, idLength: Int) -> GitIndex? {
        var index = GitIndex(paths: [], directories: [])
        var offset = 12, previous: [UInt8] = []
        for _ in 0..<count {
            let start = offset, flagsAt = start + 40 + idLength
            guard flagsAt + 2 <= bytes.count else { return nil }
            let flags = Int(bytes[flagsAt]) << 8 | Int(bytes[flagsAt + 1])
            var cursor = flagsAt + 2
            if version >= 3 && flags & 0x4000 != 0 { cursor += 2 }
            guard cursor < bytes.count else { return nil }
            var path: [UInt8]
            if version == 4 {
                // Prefix compression: drop N bytes of the previous path, then append a NUL-terminated suffix.
                guard let (strip, next) = varint(bytes, cursor), strip <= previous.count, let end = bytes[next...].firstIndex(of: 0) else { return nil }
                path = Array(previous.dropLast(strip)) + bytes[next..<end]
                offset = end + 1
            } else {
                guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
                path = Array(bytes[cursor..<end])
                // Entries are NUL-padded to a multiple of eight bytes.
                offset = start + ((end - start + 8) & ~7)
            }
            // The stored name length checks that the object name length guess was right.
            let nameLength = flags & 0x0FFF
            guard !path.isEmpty, nameLength == 0x0FFF || nameLength == path.count, offset <= bytes.count,
                  let text = String(bytes: path, encoding: .utf8) else { return nil }
            if text.hasSuffix("/") { index.directories.append(text) } else { index.paths.insert(text) }
            previous = path
        }
        // Extensions follow the entries; a split index keeps its entries in another file.
        while offset + 8 <= bytes.count - idLength {
            let signature = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            if signature == "link" { return nil }
            offset += 8 + Int(word(bytes, offset + 4))
        }
        return index
    }

    /// Git's offset varint, as used by index version 4.
    private static func varint(_ bytes: [UInt8], _ start: Int) -> (Int, Int)? {
        var cursor = start
        guard cursor < bytes.count else { return nil }
        var byte = bytes[cursor]; cursor += 1
        var value = Int(byte & 0x7f)
        while byte & 0x80 != 0 {
            guard cursor < bytes.count, value < Int.max >> 8 else { return nil }
            byte = bytes[cursor]; cursor += 1
            value = ((value + 1) << 7) | Int(byte & 0x7f)
        }
        return (value, cursor)
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}
