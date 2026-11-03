import Foundation
import GRDB

extension Source: FetchableRecord, PersistableRecord { public static let databaseTableName = "sources" }
extension TrackedFile: FetchableRecord, PersistableRecord { public static let databaseTableName = "files" }
extension Version: FetchableRecord, PersistableRecord { public static let databaseTableName = "versions" }
extension Proposal: FetchableRecord, PersistableRecord { public static let databaseTableName = "proposals" }
extension AIInvocation: FetchableRecord, PersistableRecord { public static let databaseTableName = "invocations" }

/// SQLite holds the catalog; `blobs/` holds each distinct file content once under its sha256,
/// and `manifests/` maps snapshot entries to those contents.
public final class Store: Sendable {
    public static let recentVersionLimit = 500
    public let directory: URL
    private let database: DatabaseQueue

    public init(directory: URL) throws {
        self.directory = directory
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard physicalURL(directory).path == directory.path else {
            throw HarnessError.unsafePath(directory.path)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for folder in ["blobs", "manifests"] {
            let url = directory.appendingPathComponent(folder)
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard physicalURL(url).path == url.path else { throw HarnessError.unsafePath(url.path) }
        }
        let dbURL = directory.appendingPathComponent("store.sqlite")
        if (try? dbURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw HarnessError.unsafePath(dbURL.path)
        }
        database = try DatabaseQueue(path: dbURL.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
        var migrator = DatabaseMigrator()
        // v0.1 stored every record as one JSON payload column.
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sources (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE files (id TEXT PRIMARY KEY, sourceID TEXT NOT NULL REFERENCES sources(id), payload BLOB NOT NULL);
                CREATE TABLE versions (id TEXT PRIMARY KEY, fileID TEXT NOT NULL REFERENCES files(id), capturedAt DOUBLE NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX versions_file ON versions(fileID, capturedAt);
                CREATE TABLE proposals (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE invocations (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE settings (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                """)
        }
        migrator.registerMigration("v2-columns", migrate: Self.migrateToColumns)
        migrator.registerMigration("v3-proposal-files") { db in
            try db.alter(table: "proposals") { t in t.add(column: "fileIDs", .text).notNull().defaults(to: "[]") }
            // Earlier proposals didn't record their files. Requests run one at a time, so each proposal
            // came from the latest request that completed after starting before it.
            try db.execute(sql: """
                UPDATE proposals SET fileIDs = COALESCE((SELECT invocations.fileIDs FROM invocations
                    WHERE invocations.status = 'completed' AND invocations.date < proposals.createdAt
                    ORDER BY invocations.date DESC LIMIT 1), '[]')
                """)
        }
        migrator.registerMigration("v4-decisions") { db in
            try db.create(table: "dismissals") { t in
                t.primaryKey("key", .text)
                t.column("dismissedAt", .datetime).notNull()
            }
            // Points the user decided to keep as they are, sent with later requests for the same file.
            try db.create(table: "keptNotes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileID", .text).notNull().indexed()
                t.column("proposalID", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("keptAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v5-analyses") { db in
            // File contents already analyzed with a task, so the same request isn't sent again by accident.
            try db.create(table: "analyses") { t in
                t.column("fileID", .text).notNull()
                t.column("blob", .text).notNull()
                t.column("task", .text).notNull()
                t.column("analyzedAt", .datetime).notNull()
                t.primaryKey(["fileID", "blob", "task"])
            }
            // Earlier proposals count as analyses of their base content, and only the newest pending one per file stays pending.
            for row in try Row.fetchAll(db, sql: "SELECT edits, instructions, createdAt FROM proposals WHERE edits != '[]'") {
                let instructions: String = row["instructions"], created: Date = row["createdAt"]
                for edit in try JSONDecoder().decode([ProposalEdit].self, from: Data((row["edits"] as String).utf8)) {
                    try db.execute(sql: "INSERT OR IGNORE INTO analyses (fileID, blob, task, analyzedAt) VALUES (?, ?, ?, ?)",
                                   arguments: [edit.fileID, edit.baseBlob, AIService.taskKey(instructions), created])
                }
            }
            try Self.retireSuperseded(db)
        }
        try migrator.migrate(database)
        // A quit or crash mid-request leaves no process behind; keep the activity log truthful.
        try database.write { db in try db.execute(sql: "UPDATE invocations SET status = 'interrupted' WHERE status = 'running'") }
    }

    /// Moves v0.1 payload rows into real columns. Settings keep their tolerant JSON document.
    private static func migrateToColumns(_ db: Database) throws {
        try db.drop(index: "versions_file")
        let legacy = ["sources", "files", "versions", "proposals", "invocations"]
        for table in legacy { try db.rename(table: table, to: "legacy_" + table) }
        try db.create(table: "sources") { t in
            t.primaryKey("id", .text)
            t.column("kind", .text).notNull()
            t.column("root", .text).notNull()
            t.column("name", .text).notNull()
            t.column("repositoryRoot", .text)
            t.column("isPrivate", .boolean).notNull()
            t.column("enabled", .boolean).notNull()
            t.column("lastScan", .datetime)
        }
        try db.create(table: "files") { t in
            t.primaryKey("id", .text)
            t.column("sourceID", .text).notNull().indexed().references("sources")
            t.column("path", .text).notNull()
            t.column("category", .text).notNull()
            t.column("tool", .text).notNull()
            t.column("isDirectory", .boolean).notNull()
            t.column("blob", .text)
            t.column("lastSeen", .datetime).notNull()
        }
        try db.create(table: "versions") { t in
            t.primaryKey("id", .text)
            t.column("fileID", .text).notNull().references("files")
            t.column("blob", .text)
            t.column("capturedAt", .datetime).notNull()
            t.column("origin", .text).notNull()
            t.column("note", .text).notNull()
        }
        try db.create(index: "versions_by_file", on: "versions", columns: ["fileID", "capturedAt"])
        try db.create(index: "versions_by_time", on: "versions", columns: ["capturedAt"])
        try db.create(table: "proposals") { t in
            t.primaryKey("id", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("status", .text).notNull()
            t.column("model", .text).notNull()
            t.column("rationale", .text).notNull()
            t.column("edits", .text).notNull()
            t.column("note", .text).notNull()
            t.column("instructions", .text).notNull().defaults(to: "")
        }
        try db.create(table: "invocations") { t in
            t.primaryKey("id", .text)
            t.column("date", .datetime).notNull()
            t.column("backend", .text).notNull()
            t.column("model", .text).notNull()
            t.column("fileIDs", .text).notNull()
            t.column("status", .text).notNull()
        }
        let decoder = JSONDecoder()
        for payload in try Data.fetchAll(db, sql: "SELECT payload FROM legacy_sources") { try decoder.decode(Source.self, from: payload).insert(db) }
        for payload in try Data.fetchAll(db, sql: "SELECT payload FROM legacy_files") { try decoder.decode(TrackedFile.self, from: payload).insert(db) }
        for payload in try Data.fetchAll(db, sql: "SELECT payload FROM legacy_versions ORDER BY capturedAt, rowid") { try decoder.decode(Version.self, from: payload).insert(db) }
        // Explicit columns: Proposal has since gained fields that later migrations add.
        for payload in try Data.fetchAll(db, sql: "SELECT payload FROM legacy_proposals") {
            let proposal = try decoder.decode(Proposal.self, from: payload)
            try db.execute(sql: "INSERT INTO proposals (id, createdAt, status, model, rationale, edits, note, instructions) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                           arguments: [proposal.id, proposal.createdAt, proposal.status, proposal.model, proposal.rationale,
                                       String(decoding: try JSONEncoder().encode(proposal.edits), as: UTF8.self), proposal.note, proposal.instructions])
        }
        for payload in try Data.fetchAll(db, sql: "SELECT payload FROM legacy_invocations") { try decoder.decode(AIInvocation.self, from: payload).insert(db) }
        for table in legacy.reversed() { try db.drop(table: "legacy_" + table) }
        // v0.1 labeled a file's first capture like any later change.
        try db.execute(sql: """
            UPDATE versions SET origin = 'initial'
            WHERE origin IN ('scan', 'watcher') AND blob IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM versions earlier WHERE earlier.fileID = versions.fileID
                AND (earlier.capturedAt < versions.capturedAt OR (earlier.capturedAt = versions.capturedAt AND earlier.rowid < versions.rowid)))
            """)
    }

    public func inventory() throws -> Inventory {
        try database.read { db in
            var result = Inventory()
            result.sources = try Source.fetchAll(db).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result.files = try TrackedFile.order(Column("path")).fetchAll(db)
            result.versions = try Version.order(Column("capturedAt").desc, Column.rowID.desc).limit(Self.recentVersionLimit).fetchAll(db)
            result.changes = try Version.filter(Column("origin") != "initial").order(Column("capturedAt").desc, Column.rowID.desc).limit(Self.recentVersionLimit).fetchAll(db)
            for row in try Row.fetchAll(db, sql: "SELECT fileID, COUNT(*) AS count FROM versions GROUP BY fileID") {
                result.versionCounts[row["fileID"]] = row["count"]
            }
            let today = Calendar.current.startOfDay(for: Date())
            result.changesToday = try Version
                .filter(Column("capturedAt") >= today && ["scan", "watcher", "restore", "apply"].contains(Column("origin")))
                .fetchCount(db)
            // Text-only proposals from earlier versions (recommendations, nothing-to-change notes) stay stored but aren't shown.
            result.proposals = try Proposal.filter(Column("edits") != "[]").order(Column("createdAt").desc).fetchAll(db)
            result.invocations = try AIInvocation.order(Column("date").desc).fetchAll(db)
            result.dismissed = Set(try String.fetchAll(db, sql: "SELECT key FROM dismissals"))
            return result
        }
    }

    /// Every version of one file, newest first.
    public func versions(fileID: String) throws -> [Version] {
        try database.read { db in
            try Version.filter(Column("fileID") == fileID).order(Column("capturedAt").desc, Column.rowID.desc).fetchAll(db)
        }
    }

    public func version(id: String) throws -> Version? {
        try database.read { db in try Version.fetchOne(db, key: id) }
    }

    public func save(_ source: Source) throws {
        try database.write { db in try source.save(db) }
    }

    public func capture(_ file: TrackedFile, snapshot: Snapshot?, origin: String, force: Bool = false, note: String = "") throws {
        let blob = try snapshot.map { try saveBlob($0) }
        try database.write { db in
            let existing = try TrackedFile.fetchOne(db, key: file.id)
            // A file that vanished before its first capture has nothing to track.
            if existing == nil && blob == nil { return }
            var updated = file; updated.blob = blob; updated.lastSeen = Date()
            try updated.save(db)
            guard force || existing == nil || existing?.blob != blob else { return }
            // v0.1 blobs use another encoding: the same content re-encoded only updates the identity above.
            if !force, let old = existing?.blob, let snapshot, isLegacy(old), (try? self.snapshot(blob: old)) == snapshot { return }
            // The first capture starts the timeline; it is not a change.
            let first = existing == nil && !force
            let version = Version(fileID: file.id, blob: blob, origin: first ? "initial" : origin,
                                  note: note.isEmpty ? (first ? "First captured" : blob == nil ? "File deleted" : "Content captured") : note)
            try version.insert(db)
        }
    }

    /// Loads a snapshot, optionally only some entries. Every content is verified against its address.
    public func snapshot(blob: String, entries wanted: Set<String>? = nil) throws -> Snapshot {
        guard Self.isAddress(blob) else { throw HarnessError.missingBlob }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifests/" + blob).path) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: try readAddressed(blob, in: "manifests"))
            var entries: [String: Data] = [:]
            for (path, hash) in manifest.entries where wanted?.contains(path) ?? true {
                entries[path] = try readAddressed(hash, in: "blobs")
            }
            return Snapshot(entries: entries, executablePaths: manifest.executablePaths)
        }
        // v0.1 stored whole snapshots as JSON under blobs/.
        var legacy = try JSONDecoder().decode(Snapshot.self, from: try readAddressed(blob, in: "blobs"))
        if let wanted { legacy.entries = legacy.entries.filter { wanted.contains($0.key) } }
        return legacy
    }

    @discardableResult
    private func saveBlob(_ snapshot: Snapshot) throws -> String {
        for data in snapshot.entries.values { try writeAddressed(data, hash: digest(data), in: "blobs") }
        let manifest = try snapshot.manifest.encoded(), hash = digest(manifest)
        try writeAddressed(manifest, hash: hash, in: "manifests")
        return hash
    }

    /// Content addressing makes repair safe: an existing file that fails verification is rewritten.
    private func writeAddressed(_ data: Data, hash: String, in folder: String) throws {
        let path = directory.appendingPathComponent(folder + "/" + hash)
        if FileManager.default.fileExists(atPath: path.path) {
            do { _ = try readAddressed(hash, in: folder); return }
            catch HarnessError.missingBlob { NSLog("harnessmd: Repairing corrupt store file %@", path.lastPathComponent) }
        }
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func readAddressed(_ hash: String, in folder: String) throws -> Data {
        guard Self.isAddress(hash) else { throw HarnessError.missingBlob }
        let path = directory.appendingPathComponent(folder + "/" + hash)
        let data: Data
        do {
            guard (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw HarnessError.missingBlob }
            data = try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw HarnessError.missingBlob
        }
        guard digest(data) == hash else { throw HarnessError.missingBlob }
        return data
    }

    private static func isAddress(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }

    /// A v0.1 whole-snapshot blob has no manifest.
    private func isLegacy(_ blob: String) -> Bool {
        Self.isAddress(blob) && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifests/" + blob).path)
    }

    public func save(_ proposal: Proposal) throws {
        try database.write { db in try proposal.save(db) }
    }

    public func setDismissed(_ key: String, _ dismissed: Bool) throws {
        try database.write { db in
            if dismissed { try db.execute(sql: "INSERT OR REPLACE INTO dismissals (key, dismissedAt) VALUES (?, ?)", arguments: [key, Date()]) }
            else { try db.execute(sql: "DELETE FROM dismissals WHERE key = ?", arguments: [key]) }
        }
    }

    /// Marks a proposal kept and remembers its points per file, in one transaction.
    public func keep(_ proposal: Proposal, notes: [(fileID: String, text: String)]) throws {
        try database.write { db in
            var kept = proposal; kept.status = "kept"
            try kept.save(db)
            for note in notes {
                try db.execute(sql: "INSERT INTO keptNotes (fileID, proposalID, text, keptAt) VALUES (?, ?, ?, ?)", arguments: [note.fileID, proposal.id, note.text, Date()])
            }
        }
    }

    /// Puts a kept proposal back in review and forgets its points.
    public func reopen(_ proposal: Proposal) throws {
        try database.write { db in
            var open = proposal; open.status = "pending"
            try open.save(db)
            try db.execute(sql: "DELETE FROM keptNotes WHERE proposalID = ?", arguments: [proposal.id])
        }
    }

    /// Kept points by file, oldest first.
    public func keptNotes(fileIDs: Set<String>) throws -> [String: [String]] {
        try database.read { db in
            var notes: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT fileID, text FROM keptNotes ORDER BY id") where fileIDs.contains(row["fileID"]) {
                notes[row["fileID"], default: []].append(row["text"])
            }
            return notes
        }
    }

    /// Saves a new proposal. Older pending proposals for any of its files become `replaced`, so each file has one diff waiting.
    public func saveNewest(_ proposal: Proposal) throws {
        try database.write { db in
            try proposal.save(db)
            try Self.retireSuperseded(db)
        }
    }

    /// Keeps the newest pending proposal per file; older pending ones that touch the same files become `replaced`.
    static func retireSuperseded(_ db: Database) throws {
        var claimed = Set<String>()
        for var proposal in try Proposal.filter(Column("status") == "pending" && Column("edits") != "[]").order(Column("createdAt").desc).fetchAll(db) {
            let files = Set(proposal.edits.map(\.fileID))
            if !files.isDisjoint(with: claimed) { proposal.status = "replaced"; try proposal.update(db) }
            claimed.formUnion(files)
        }
    }

    public func recordAnalysis(of files: [(fileID: String, blob: String)], task: String) throws {
        try database.write { db in
            for file in files {
                try db.execute(sql: "INSERT OR REPLACE INTO analyses (fileID, blob, task, analyzedAt) VALUES (?, ?, ?, ?)", arguments: [file.fileID, file.blob, task, Date()])
            }
        }
    }

    /// For each file, the tasks its current content was already analyzed with.
    public func analyzedTasks(of files: [(fileID: String, blob: String)]) throws -> [String: Set<String>] {
        try database.read { db in
            var tasks: [String: Set<String>] = [:]
            for file in files {
                let found = try String.fetchAll(db, sql: "SELECT task FROM analyses WHERE fileID = ? AND blob = ?", arguments: [file.fileID, file.blob])
                if !found.isEmpty { tasks[file.fileID] = Set(found) }
            }
            return tasks
        }
    }

    public func save(_ invocation: AIInvocation) throws {
        try database.write { db in try invocation.save(db) }
    }

    public func settings() throws -> AppSettings {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM settings WHERE id = 'app'") else { return AppSettings() }
            return try JSONDecoder().decode(AppSettings.self, from: data)
        }
    }
    public func save(_ settings: AppSettings) throws {
        let payload = try JSONEncoder().encode(settings)
        try database.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('app', ?)", arguments: [payload]) }
    }
}
