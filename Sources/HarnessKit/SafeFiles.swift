import Foundation
import Darwin

/// Traversal uses directory descriptors and O_NOFOLLOW, including the source root's ancestors.
/// Restores never follow a symlink or modify a hard-linked inode.
public enum SafeFiles {
    public static func components(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.isEmpty else { throw HarnessError.unsafePath(path) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw HarnessError.unsafePath(path)
        }
        return parts
    }

    private static func rootFD(_ root: String) throws -> Int32 {
        guard root.hasPrefix("/"), !root.contains("\0") else { throw HarnessError.unsafePath(root) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix(root) }
        for part in root.split(separator: "/").map(String.init) {
            guard part != ".", part != ".." else { close(fd); throw HarnessError.unsafePath(root) }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw posix(root) }
            fd = next
        }
        return fd
    }

    private static func parentFD(root: String, path: String, create: Bool = false) throws -> (Int32, String) {
        let parts = try components(path)
        var fd = try rootFD(root)
        for part in parts.dropLast() {
            if create && mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { close(fd); throw posix(path) }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw posix(path) }
            fd = next
        }
        return (fd, parts.last!)
    }

    public static func read(root: String, path: String) throws -> Data? {
        let parent: (Int32, String)
        do { parent = try parentFD(root: root, path: path) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        let (fd, name) = parent; defer { close(fd) }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw posix(path) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw HarnessError.unsafePath(path) }
        guard info.st_size <= Privacy.maxFileBytes else { throw HarnessError.invalid("File exceeds the 1 MiB collection limit: \(path)") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw posix(path) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Privacy.maxFileBytes else { throw HarnessError.invalid("File exceeds collection limit: \(path)") }
        }
        return data
    }

    public static func write(_ data: Data, root: String, path: String, executable: Bool? = nil) throws {
        guard !Privacy.denied(path) else { throw HarnessError.blocked(path) }
        let (fd, name) = try parentFD(root: root, path: path, create: true); defer { close(fd) }
        var info = stat()
        let exists = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if exists && (info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1) { throw HarnessError.unsafePath(path) }
        if !exists && errno != ENOENT { throw posix(path) }
        let temporary = ".harnessmd-" + UUID().uuidString
        let out = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw posix(path) }
        defer { close(out); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw posix(path) }
                offset += count
            }
        }
        var mode: mode_t = exists ? info.st_mode & 0o777 : 0o600
        if let executable { mode = executable ? mode | 0o100 : mode & ~0o111 }
        guard fchmod(out, mode) == 0 else { throw posix(path) }
        guard fsync(out) == 0, renameat(fd, temporary, fd, name) == 0 else { throw posix(path) }
    }

    public static func capture(root: String, file: TrackedFile) throws -> Snapshot? {
        if !file.isDirectory {
            guard let data = try read(root: root, path: file.path) else { return nil }
            try Privacy.validate(data, path: file.path)
            return Snapshot(entries: ["": data], executablePaths: try isExecutable(root: root, path: file.path) ? [""] : [])
        }
        let base = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        // Opening this descriptor validates every ancestor before enumeration.
        let descriptor: Int32
        do { descriptor = try rootFD(base.path) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        defer { close(descriptor) }
        var entries: [String: Data] = [:]; var size = 0; var executablePaths: [String] = []
        var traversalError: Error?
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            traversalError = error; return false
        }) else { throw HarnessError.invalid("Cannot read skill: \(file.path)") }
        for case let url as URL in iterator {
            let relative = String(url.path.dropFirst(base.path.count + 1))
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true, Privacy.junkDirectories.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            if values.isDirectory != true, Privacy.isJunk(url.lastPathComponent) { continue }
            // A partial bundle would restore incompletely, so a link or denied entry blocks the whole skill.
            guard values.isSymbolicLink != true else { throw HarnessError.unsafePath(file.path + "/" + relative) }
            guard !Privacy.denied(relative) else { throw HarnessError.blocked(file.path + "/" + relative) }
            guard values.isRegularFile == true else { continue }
            guard let data = try read(root: root, path: file.path + "/" + relative) else { throw HarnessError.conflict }
            if relative == "SKILL.md" { try Privacy.validate(data, path: relative) } else { try Privacy.validateBundleEntry(data, path: relative) }
            size += data.count
            guard size <= Privacy.maxSnapshotBytes, entries.count < 1000 else { throw HarnessError.invalid("Skill exceeds 8 MiB or 1000 files: \(file.path)") }
            entries[relative] = data
            if try isExecutable(root: root, path: file.path + "/" + relative) { executablePaths.append(relative) }
        }
        if let traversalError { throw traversalError }
        return Snapshot(entries: entries, executablePaths: executablePaths)
    }

    public static func restore(_ snapshot: Snapshot, root: String, file: TrackedFile) throws {
        if !file.isDirectory {
            guard snapshot.entries.count == 1, let data = snapshot.entries[""] else { throw HarnessError.missingBlob }
            try Privacy.validate(data, path: file.path)
            try write(data, root: root, path: file.path, executable: snapshot.executablePaths.contains(""))
            return
        }
        // Preserve unversioned/new files rather than deleting user content. Every bundled entry is restored.
        for (path, data) in snapshot.entries.sorted(by: { $0.key < $1.key }) {
            _ = try components(path)
            if path == "SKILL.md" { try Privacy.validate(data, path: path) } else { try Privacy.validateBundleEntry(data, path: path) }
        }
        for (path, data) in snapshot.entries.sorted(by: { $0.key < $1.key }) {
            try write(data, root: root, path: file.path + "/" + path, executable: snapshot.executablePaths.contains(path))
        }
    }

    private static func isExecutable(root: String, path: String) throws -> Bool {
        let (parent, name) = try parentFD(root: root, path: path); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { throw HarnessError.unsafePath(path) }
        return info.st_mode & 0o111 != 0
    }

    private static func posix(_ path: String) -> Error {
        if errno == ELOOP || errno == ENOTDIR { return HarnessError.unsafePath(path) }
        return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
