import GRDB
import XCTest
@testable import NotebookApp

final class IndexStoreTests: XCTestCase {
    private var store: IndexStore!

    override func setUpWithError() throws {
        store = try IndexStore(dbQueue: DatabaseQueue())
    }

    func testUpsertThenSearchFindsPage() throws {
        let notebookID = UUID()
        let pageID = UUID()
        try store.upsert(notebookID: notebookID, pageID: pageID, contentHash: "h1", text: "Fourier transform basics")

        let results = try store.search("Fourier")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.pageID, pageID)
    }

    /// §8: keyed by (pageID, contentHash) — a stale entry is simply overwritten on the
    /// next pass rather than accumulating duplicates.
    func testReindexingWithNewHashReplacesOldText() throws {
        let notebookID = UUID()
        let pageID = UUID()
        try store.upsert(notebookID: notebookID, pageID: pageID, contentHash: "h1", text: "old content about cats")
        try store.upsert(notebookID: notebookID, pageID: pageID, contentHash: "h2", text: "new content about dogs")

        XCTAssertTrue(try store.search("cats").isEmpty)
        XCTAssertEqual(try store.search("dogs").count, 1)
    }

    func testRebuildFromScratchClearsIndex() throws {
        let notebookID = UUID()
        let pageID = UUID()
        try store.upsert(notebookID: notebookID, pageID: pageID, contentHash: "h1", text: "searchable text")
        XCTAssertEqual(try store.search("searchable").count, 1)

        try store.rebuildFromScratch()
        XCTAssertTrue(try store.search("searchable").isEmpty)
    }

    /// FTS5 MATCH treats punctuation/operators specially; arbitrary user text (e.g.
    /// annotation content containing quotes) must not throw a syntax error.
    func testSearchQueryWithSpecialCharactersDoesNotThrow() throws {
        XCTAssertNoThrow(try store.search("AND OR \"quoted\" -minus"))
    }
}
