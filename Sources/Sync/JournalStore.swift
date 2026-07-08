import Foundation
import GRDB

/// Sentinel page_id used for manifest-level journal rows (page reorders, inserts,
/// deletes — anything that only touches `manifest.json`).
enum JournalPageID {
    static let manifest = "MANIFEST"
}

struct JournalEntry: Codable, FetchableRecord, PersistableRecord, Equatable {
    var seq: Int64?
    var notebookID: String
    var pageID: String
    var contentHash: String
    var deviceID: String
    var changedAt: Int64 // unix ms

    static let databaseTableName = "journal"

    enum CodingKeys: String, CodingKey {
        case seq
        case notebookID = "notebook_id"
        case pageID = "page_id"
        case contentHash = "content_hash"
        case deviceID = "device_id"
        case changedAt = "changed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}

enum SyncCloud: String, Codable {
    case icloud
    case gdrive
}

struct SyncCheckpoint: Codable, FetchableRecord, PersistableRecord, Equatable {
    var cloud: String
    var notebookID: String
    var pageID: String
    var syncedHash: String
    var syncedSeq: Int64
    var syncedAt: Int64

    static let databaseTableName = "sync_checkpoint"

    enum CodingKeys: String, CodingKey {
        case cloud
        case notebookID = "notebook_id"
        case pageID = "page_id"
        case syncedHash = "synced_hash"
        case syncedSeq = "synced_seq"
        case syncedAt = "synced_at"
    }
}

/// Persisted per-(cloud, page) sync state so a crash mid-upload resumes rather than
/// re-uploads, and a conflict discovered mid-upload survives across launches (§6.2).
struct SyncStateRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    var cloud: String
    var notebookID: String
    var pageID: String
    var state: String // raw value of PageSyncState
    var updatedAt: Int64

    static let databaseTableName = "sync_state"

    enum CodingKeys: String, CodingKey {
        case cloud
        case notebookID = "notebook_id"
        case pageID = "page_id"
        case state
        case updatedAt = "updated_at"
    }
}

/// A page whose latest journal hash differs from a cloud's checkpoint hash — i.e. it
/// needs to be pushed to that cloud. Computed by diffing journal against checkpoint,
/// per §6.1: "This cleanly decouples 'what changed' from 'what has been pushed where'."
struct PendingUpload: Equatable {
    let pageID: String
    let contentHash: String
    let seq: Int64
}

/// Owns `journal.sqlite` — the change journal, sync checkpoints, and per-(cloud, page)
/// sync state. Local-only; this database must never enter the synced package (§3.2).
final class JournalStore {
    private let dbQueue: DatabaseQueue

    init(notebookID: UUID) throws {
        let url = try PackageLayout.journalDatabaseURL(notebookID: notebookID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(dbQueue)
    }

    /// Test/in-memory constructor.
    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_journal_checkpoint_state") { db in
            try db.create(table: "journal") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("notebook_id", .text).notNull()
                t.column("page_id", .text).notNull()
                t.column("content_hash", .text).notNull()
                t.column("device_id", .text).notNull()
                t.column("changed_at", .integer).notNull()
            }
            try db.create(index: "idx_journal_notebook_page", on: "journal", columns: ["notebook_id", "page_id"])

            try db.create(table: "sync_checkpoint") { t in
                t.column("cloud", .text).notNull()
                t.column("notebook_id", .text).notNull()
                t.column("page_id", .text).notNull()
                t.column("synced_hash", .text).notNull()
                t.column("synced_seq", .integer).notNull()
                t.column("synced_at", .integer).notNull()
                t.primaryKey(["cloud", "notebook_id", "page_id"])
            }

            try db.create(table: "sync_state") { t in
                t.column("cloud", .text).notNull()
                t.column("notebook_id", .text).notNull()
                t.column("page_id", .text).notNull()
                t.column("state", .text).notNull()
                t.column("updated_at", .integer).notNull()
                t.primaryKey(["cloud", "notebook_id", "page_id"])
            }
        }
        return migrator
    }

    // MARK: - Journal writes

    /// Appends a journal row. Must only be called *after* the corresponding atomic
    /// file write has already succeeded — this ordering invariant is what lets crash
    /// recovery trust the journal (§2, §5).
    @discardableResult
    func appendEntry(
        notebookID: UUID,
        pageID: String,
        contentHash: String,
        deviceID: String = DeviceIdentity.current,
        changedAt: Date = Date()
    ) throws -> JournalEntry {
        var entry = JournalEntry(
            seq: nil,
            notebookID: notebookID.uuidString,
            pageID: pageID,
            contentHash: contentHash,
            deviceID: deviceID,
            changedAt: Int64(changedAt.timeIntervalSince1970 * 1000)
        )
        try dbQueue.write { db in
            try entry.insert(db)
        }
        return entry
    }

    /// The latest journal row per page — i.e. current known-good state per page.
    func latestEntries(notebookID: UUID) throws -> [JournalEntry] {
        try dbQueue.read { db in
            try JournalEntry.fetchAll(
                db,
                sql: """
                SELECT j.* FROM journal j
                INNER JOIN (
                    SELECT page_id, MAX(seq) AS max_seq
                    FROM journal
                    WHERE notebook_id = ?
                    GROUP BY page_id
                ) latest ON j.page_id = latest.page_id AND j.seq = latest.max_seq
                WHERE j.notebook_id = ?
                """,
                arguments: [notebookID.uuidString, notebookID.uuidString]
            )
        }
    }

    func latestEntry(notebookID: UUID, pageID: String) throws -> JournalEntry? {
        try dbQueue.read { db in
            try JournalEntry
                .filter(Column("notebook_id") == notebookID.uuidString && Column("page_id") == pageID)
                .order(Column("seq").desc)
                .fetchOne(db)
        }
    }

    // MARK: - Checkpoints

    func checkpoint(cloud: SyncCloud, notebookID: UUID, pageID: String) throws -> SyncCheckpoint? {
        try dbQueue.read { db in
            try SyncCheckpoint
                .filter(Column("cloud") == cloud.rawValue
                        && Column("notebook_id") == notebookID.uuidString
                        && Column("page_id") == pageID)
                .fetchOne(db)
        }
    }

    func setCheckpoint(
        cloud: SyncCloud, notebookID: UUID, pageID: String, syncedHash: String, syncedSeq: Int64, syncedAt: Date = Date()
    ) throws {
        let checkpoint = SyncCheckpoint(
            cloud: cloud.rawValue,
            notebookID: notebookID.uuidString,
            pageID: pageID,
            syncedHash: syncedHash,
            syncedSeq: syncedSeq,
            syncedAt: Int64(syncedAt.timeIntervalSince1970 * 1000)
        )
        try dbQueue.write { db in
            try checkpoint.save(db)
        }
    }

    /// Diffs latest journal hash per page against this cloud's checkpoint hash to
    /// compute what still needs to be pushed (§6.1).
    func pendingUploads(cloud: SyncCloud, notebookID: UUID) throws -> [PendingUpload] {
        let latest = try latestEntries(notebookID: notebookID)
        return try dbQueue.read { db in
            var pending: [PendingUpload] = []
            for entry in latest {
                let checkpoint = try SyncCheckpoint
                    .filter(Column("cloud") == cloud.rawValue
                            && Column("notebook_id") == notebookID.uuidString
                            && Column("page_id") == entry.pageID)
                    .fetchOne(db)
                if checkpoint?.syncedHash != entry.contentHash {
                    pending.append(PendingUpload(pageID: entry.pageID, contentHash: entry.contentHash, seq: entry.seq ?? 0))
                }
            }
            return pending
        }
    }

    // MARK: - Per-(cloud, page) sync state

    func setState(_ state: PageSyncState, cloud: SyncCloud, notebookID: UUID, pageID: String) throws {
        let row = SyncStateRow(
            cloud: cloud.rawValue,
            notebookID: notebookID.uuidString,
            pageID: pageID,
            state: state.rawValue,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try dbQueue.write { db in
            try row.save(db)
        }
    }

    func state(cloud: SyncCloud, notebookID: UUID, pageID: String) throws -> PageSyncState {
        try dbQueue.read { db in
            let row = try SyncStateRow
                .filter(Column("cloud") == cloud.rawValue
                        && Column("notebook_id") == notebookID.uuidString
                        && Column("page_id") == pageID)
                .fetchOne(db)
            return row.flatMap { PageSyncState(rawValue: $0.state) } ?? .idle
        }
    }

    // MARK: - Compaction

    /// The journal is recent history, not an eternal log. For each page, deletes rows
    /// older than the oldest checkpoint every active cloud has reached — the journal
    /// only needs to bridge the gap since the slowest cloud's last successful sync
    /// (§6.1). A page with no checkpoint yet for some active cloud is left alone.
    func compact(notebookID: UUID, activeClouds: [SyncCloud], rowCountTrigger: Int = 10_000) throws {
        let totalRows = try dbQueue.read { db in
            try JournalEntry.filter(Column("notebook_id") == notebookID.uuidString).fetchCount(db)
        }
        guard totalRows > rowCountTrigger else { return }
        guard !activeClouds.isEmpty else { return }

        try dbQueue.write { db in
            let pageIDs = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT page_id FROM journal WHERE notebook_id = ?",
                arguments: [notebookID.uuidString]
            )
            for pageID in pageIDs {
                var minSyncedSeq: Int64?
                for cloud in activeClouds {
                    guard let checkpoint = try SyncCheckpoint
                        .filter(Column("cloud") == cloud.rawValue
                                && Column("notebook_id") == notebookID.uuidString
                                && Column("page_id") == pageID)
                        .fetchOne(db)
                    else {
                        minSyncedSeq = nil
                        break
                    }
                    minSyncedSeq = min(minSyncedSeq ?? checkpoint.syncedSeq, checkpoint.syncedSeq)
                }
                guard let safeSeq = minSyncedSeq else { continue }
                try db.execute(
                    sql: "DELETE FROM journal WHERE notebook_id = ? AND page_id = ? AND seq < ?",
                    arguments: [notebookID.uuidString, pageID, safeSeq]
                )
            }
        }
    }

    /// Startup reconciliation (§10): if the app crashed after a file write but before
    /// its journal row landed, the journal lags reality by one entry. Callers pass the
    /// current on-disk hash per page; any mismatch against the latest journal entry
    /// gets a synthesized row appended so the journal catches up to disk truth.
    func reconcileOnLaunch(notebookID: UUID, onDiskHashes: [String: String]) throws {
        for (pageID, hash) in onDiskHashes {
            let latest = try latestEntry(notebookID: notebookID, pageID: pageID)
            if latest?.contentHash != hash {
                try appendEntry(notebookID: notebookID, pageID: pageID, contentHash: hash)
            }
        }
    }
}
