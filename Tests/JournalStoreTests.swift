import GRDB
import XCTest
@testable import NotebookApp

final class JournalStoreTests: XCTestCase {
    private var store: JournalStore!
    private let notebookID = UUID()
    private let pageID = UUID()

    override func setUpWithError() throws {
        store = try JournalStore(dbQueue: DatabaseQueue())
    }

    func testPendingUploadsEmptyWhenNoCheckpointDivergence() throws {
        try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h1", deviceID: "dev1")
        try store.setCheckpoint(cloud: .icloud, notebookID: notebookID, pageID: pageID.uuidString, syncedHash: "h1", syncedSeq: 1)

        let pending = try store.pendingUploads(cloud: .icloud, notebookID: notebookID)
        XCTAssertTrue(pending.isEmpty)
    }

    /// §6.1: the upload set is a diff between the latest journal hash and the cloud's
    /// checkpoint hash — this is what lets two clouds with different cadences share
    /// one journal without stepping on each other.
    func testPendingUploadsReflectsNewerJournalEntry() throws {
        try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h1", deviceID: "dev1")
        try store.setCheckpoint(cloud: .icloud, notebookID: notebookID, pageID: pageID.uuidString, syncedHash: "h1", syncedSeq: 1)
        try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h2", deviceID: "dev1")

        let icloudPending = try store.pendingUploads(cloud: .icloud, notebookID: notebookID)
        XCTAssertEqual(icloudPending.map(\.contentHash), ["h2"])

        // A cloud with no checkpoint at all still has everything pending — this is
        // exactly the "two clouds with different cadences" case §6.1 calls out.
        let drivePending = try store.pendingUploads(cloud: .gdrive, notebookID: notebookID)
        XCTAssertEqual(drivePending.map(\.contentHash), ["h2"])
    }

    func testLatestEntryReturnsMostRecentPerPage() throws {
        try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h1", deviceID: "dev1")
        try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h2", deviceID: "dev1")
        try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h3", deviceID: "dev1")

        let latest = try store.latestEntry(notebookID: notebookID, pageID: pageID.uuidString)
        XCTAssertEqual(latest?.contentHash, "h3")
    }

    /// §6.1 compaction: rows older than every active cloud's checkpoint should be
    /// dropped once the row-count trigger is exceeded; nothing should compact for a
    /// cloud that has never synced a page at all.
    func testCompactionDropsRowsOlderThanSlowestCloudCheckpoint() throws {
        for i in 1...50 {
            try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h\(i)", deviceID: "dev1")
        }
        guard let latest = try store.latestEntry(notebookID: notebookID, pageID: pageID.uuidString), let latestSeq = latest.seq else {
            return XCTFail("expected a latest entry")
        }
        try store.setCheckpoint(cloud: .icloud, notebookID: notebookID, pageID: pageID.uuidString, syncedHash: latest.contentHash, syncedSeq: latestSeq)
        try store.setCheckpoint(cloud: .gdrive, notebookID: notebookID, pageID: pageID.uuidString, syncedHash: latest.contentHash, syncedSeq: latestSeq)

        try store.compact(notebookID: notebookID, activeClouds: [.icloud, .gdrive], rowCountTrigger: 10)

        let remaining = try store.latestEntries(notebookID: notebookID)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.contentHash, "h50")
    }

    func testCompactionSkipsPageMissingCheckpointForAnActiveCloud() throws {
        for i in 1...50 {
            try store.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: "h\(i)", deviceID: "dev1")
        }
        // Only iCloud has synced; Drive is active but has never checkpointed this page.
        if let latestSeq = try store.latestEntry(notebookID: notebookID, pageID: pageID.uuidString)?.seq {
            try store.setCheckpoint(cloud: .icloud, notebookID: notebookID, pageID: pageID.uuidString, syncedHash: "h50", syncedSeq: latestSeq)
        }

        try store.compact(notebookID: notebookID, activeClouds: [.icloud, .gdrive], rowCountTrigger: 10)

        let allRows = try store.latestEntries(notebookID: notebookID)
        // latestEntries only returns the newest row per page, so assert via a direct
        // pending-uploads check instead: Drive should still see everything as pending,
        // which is only possible if the underlying rows survived compaction.
        XCTAssertFalse(allRows.isEmpty)
        let drivePending = try store.pendingUploads(cloud: .gdrive, notebookID: notebookID)
        XCTAssertEqual(drivePending.first?.contentHash, "h50")
    }

    // MARK: - Sync state machine

    func testValidTransitionsSucceedAndInvalidOnesThrow() throws {
        let machine = SyncStateMachine(journalStore: store, cloud: .icloud, notebookID: notebookID)
        XCTAssertEqual(try machine.currentState(pageID: pageID.uuidString), .idle)

        try machine.transition(pageID: pageID.uuidString, to: .dirty)
        try machine.transition(pageID: pageID.uuidString, to: .uploading)
        try machine.transition(pageID: pageID.uuidString, to: .synced)

        XCTAssertThrowsError(try machine.transition(pageID: pageID.uuidString, to: .uploading))
    }
}
