import Foundation
import GRDB

struct SearchResult: Equatable {
    let notebookID: UUID
    let pageID: UUID
    let snippet: String
}

/// Owns `index.sqlite`: library metadata and the FTS5 search table (§8). Purely a
/// rebuildable cache (P2) — if this file is missing or corrupt, delete and rescan the
/// packages. Never the source of truth for anything.
///
/// One `index.sqlite` covers the whole library (unlike `journal.sqlite`, which is
/// per-notebook), since cross-notebook search is a basic library feature.
final class IndexStore {
    private let dbQueue: DatabaseQueue

    init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = appSupport.appendingPathComponent("index.sqlite")
        dbQueue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_fts") { db in
            try db.create(virtualTable: "page_text_fts", using: FTS5()) { t in
                t.column("text")
                t.column("page_id").notIndexed()
                t.column("notebook_id").notIndexed()
            }
            // Idempotency ledger: lets `upsert` skip re-indexing an unchanged page and
            // lets a full rebuild just re-enqueue every page (§8).
            try db.create(table: "indexed_pages") { t in
                t.column("page_id", .text).primaryKey()
                t.column("notebook_id", .text).notNull()
                t.column("content_hash", .text).notNull()
            }
        }
        return migrator
    }

    /// Keyed by `(pageID, contentHash)` so a stale entry is simply overwritten on the
    /// next pass, and a full rebuild is just re-enqueueing every page (§8).
    func upsert(notebookID: UUID, pageID: UUID, contentHash: String, text: String) throws {
        try dbQueue.write { db in
            let existingHash = try String.fetchOne(
                db, sql: "SELECT content_hash FROM indexed_pages WHERE page_id = ?", arguments: [pageID.uuidString]
            )
            guard existingHash != contentHash else { return }

            try db.execute(sql: "DELETE FROM page_text_fts WHERE page_id = ?", arguments: [pageID.uuidString])
            try db.execute(
                sql: "INSERT INTO page_text_fts (text, page_id, notebook_id) VALUES (?, ?, ?)",
                arguments: [text, pageID.uuidString, notebookID.uuidString]
            )
            try db.execute(
                sql: """
                INSERT INTO indexed_pages (page_id, notebook_id, content_hash) VALUES (?, ?, ?)
                ON CONFLICT(page_id) DO UPDATE SET content_hash = excluded.content_hash, notebook_id = excluded.notebook_id
                """,
                arguments: [pageID.uuidString, notebookID.uuidString, contentHash]
            )
        }
    }

    func removePage(pageID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM page_text_fts WHERE page_id = ?", arguments: [pageID.uuidString])
            try db.execute(sql: "DELETE FROM indexed_pages WHERE page_id = ?", arguments: [pageID.uuidString])
        }
    }

    /// §11 target: cold search over 10k pages < 500ms via FTS5 + prebuilt index.
    func search(_ query: String, limit: Int = 50) throws -> [SearchResult] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT page_id, notebook_id, snippet(page_text_fts, 0, '', '', '…', 12) AS snippet
                FROM page_text_fts
                WHERE page_text_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                arguments: [Self.sanitizeMatchQuery(query), limit]
            )
            return rows.compactMap { row in
                guard let pageIDString: String = row["page_id"],
                      let notebookIDString: String = row["notebook_id"],
                      let pageID = UUID(uuidString: pageIDString),
                      let notebookID = UUID(uuidString: notebookIDString) else {
                    return nil
                }
                return SearchResult(notebookID: notebookID, pageID: pageID, snippet: row["snippet"])
            }
        }
    }

    /// Rebuild support (§8, §10): drop and recreate, then callers re-enqueue every
    /// page through `upsert`.
    func rebuildFromScratch() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM page_text_fts")
            try db.execute(sql: "DELETE FROM indexed_pages")
        }
    }

    /// FTS5 MATCH treats bare punctuation specially; wrap raw user input as a phrase
    /// query so arbitrary search text (including PencilKit annotation content that may
    /// contain FTS operators) doesn't throw a syntax error.
    private static func sanitizeMatchQuery(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
