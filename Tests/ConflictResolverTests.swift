import PencilKit
import XCTest
@testable import NotebookApp

final class ConflictResolverTests: XCTestCase {

    /// §7.1: same hash is never a conflict, regardless of local dirty state.
    func testIdenticalHashesAreNeverAConflict() {
        XCTAssertFalse(ConflictResolver.isConflict(localHash: "h1", remoteHash: "h1", localHasUnsyncedChanges: true))
        XCTAssertFalse(ConflictResolver.isConflict(localHash: "h1", remoteHash: "h1", localHasUnsyncedChanges: false))
    }

    /// §7.1: "Clean local page + different remote hash is not a conflict — it's a
    /// normal download."
    func testDifferentHashWithCleanLocalIsNormalDownloadNotConflict() {
        XCTAssertFalse(ConflictResolver.isConflict(localHash: "h1", remoteHash: "h2", localHasUnsyncedChanges: false))
    }

    func testDifferentHashWithDirtyLocalIsAConflict() {
        XCTAssertTrue(ConflictResolver.isConflict(localHash: "h1", remoteHash: "h2", localHasUnsyncedChanges: true))
    }

    /// v1.0 ships detection + both-versions-kept only — no merge (§7.4). Even when a
    /// merge would otherwise succeed cleanly, `mergeEnabled: false` must still fall
    /// back so the rollout phasing is actually enforced, not just documented.
    func testMergeDisabledAlwaysFallsBackOnConflict() {
        let notebookID = UUID()
        let pageID = UUID()
        let a = TestStrokeFactory.stroke(startingAt: 0)
        let mine = PKDrawing(strokes: [a, TestStrokeFactory.stroke(startingAt: 50)])
        let theirs = PKDrawing(strokes: [a, TestStrokeFactory.stroke(startingAt: 150)])

        let decision = ConflictResolver.decide(
            notebookID: notebookID, pageID: pageID,
            localHash: "h1", remoteHash: "h2", localHasUnsyncedChanges: true,
            localDrawing: mine, remoteDrawing: theirs, mergeEnabled: false
        )

        guard case .bothVersionsKept = decision else {
            return XCTFail("Expected both-versions-kept fallback when merge is disabled (v1.0 phasing)")
        }
    }

    func testNonConflictAppliesRemoteEvenWithMergeEnabled() {
        let decision = ConflictResolver.decide(
            notebookID: UUID(), pageID: UUID(),
            localHash: "h1", remoteHash: "h2", localHasUnsyncedChanges: false,
            localDrawing: PKDrawing(), remoteDrawing: PKDrawing(), mergeEnabled: true
        )
        guard case .applyRemote = decision else {
            return XCTFail("Expected a clean local page to just apply the remote version")
        }
    }
}
