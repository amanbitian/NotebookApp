import Foundation
import PencilKit

/// Policy from §7: page-level conflict detection → 3-way stroke-level merge →
/// both-versions-kept snapshot fallback. Never silent last-write-wins (P4).
enum ConflictResolver {

    /// §7.1: a page is in conflict when the remote hash differs from local *and* the
    /// local page has journal entries newer than the last checkpoint for that page.
    /// A clean local page with a different remote hash is not a conflict — it's a
    /// normal download.
    static func isConflict(localHash: String, remoteHash: String, localHasUnsyncedChanges: Bool) -> Bool {
        guard localHash != remoteHash else { return false }
        return localHasUnsyncedChanges
    }

    enum Decision {
        /// Not a conflict: apply the incoming remote version outright.
        case applyRemote
        /// v1.1+: merge succeeded, apply the merged drawing.
        case applyMerged(PKDrawing)
        /// Merge aborted or not yet enabled (v1.0): keep both, surface a badge, defer
        /// to the user. Resolving is a user action, never a timeout (§7.3).
        case bothVersionsKept(PageConflict)
    }

    /// `mergeEnabled` reflects the rollout phasing in §7.4: v1.0 ships detection +
    /// both-versions-kept only; v1.1 turns this on for pure-ink pages. Flip it once
    /// the merge path has been validated in the field — everything upstream (journal,
    /// checkpoints, merge-base plumbing) already exists from v1.0, so this is the only
    /// switch v1.1 needs to flip (§7.4 closing note).
    static func decide(
        notebookID: UUID,
        pageID: UUID,
        localHash: String,
        remoteHash: String,
        localHasUnsyncedChanges: Bool,
        localDrawing: PKDrawing,
        remoteDrawing: PKDrawing,
        mergeEnabled: Bool
    ) -> Decision {
        guard isConflict(localHash: localHash, remoteHash: remoteHash, localHasUnsyncedChanges: localHasUnsyncedChanges) else {
            return .applyRemote
        }

        guard mergeEnabled else {
            return .bothVersionsKept(makeConflict(pageID: pageID, localHash: localHash, remoteHash: remoteHash))
        }

        let base = MergeBaseStore.load(notebookID: notebookID, pageID: pageID)
        switch ThreeWayMerge.merge(base: base, mine: localDrawing, theirs: remoteDrawing) {
        case .merged(let drawing):
            return .applyMerged(drawing)
        case .fallback:
            return .bothVersionsKept(makeConflict(pageID: pageID, localHash: localHash, remoteHash: remoteHash))
        }
    }

    private static func makeConflict(pageID: UUID, localHash: String, remoteHash: String) -> PageConflict {
        PageConflict(
            pageID: pageID,
            localSnapshotHash: localHash,
            remoteSnapshotHash: remoteHash,
            detectedAt: Date()
        )
    }
}
