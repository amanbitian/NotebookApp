import Foundation
import PencilKit

/// User-driven resolution for a page left in both-versions-kept fallback mode (§7.3).
/// The system has already picked one version as active (the newer one) and stashed the
/// other in `ConflictVersionStore`; these three actions are the only way out — there is
/// no timeout-based auto-resolution (§7.3, P4).
@MainActor
enum ConflictResolutionActions {

    /// "Keep this": discard the stashed alternate version, clear the conflict badge.
    static func keepActive(notebook: Notebook, pageID: UUID) {
        guard let conflict = notebook.page(for: pageID)?.conflict else { return }
        let stashedHash = conflict.localSnapshotHash == currentHash(notebook: notebook, pageID: pageID)
            ? conflict.remoteSnapshotHash
            : conflict.localSnapshotHash
        try? ConflictVersionStore.discard(notebookID: notebook.id, pageID: pageID, hash: stashedHash)
        notebook.page(for: pageID)?.setConflict(nil)
    }

    /// "Keep that": swap in the stashed version as the page's active content.
    static func keepStashed(notebook: Notebook, pageID: UUID, journalStore: JournalStore, packageURL: URL) {
        guard let conflict = notebook.page(for: pageID)?.conflict else { return }
        let activeHash = currentHash(notebook: notebook, pageID: pageID)
        let stashedHash = conflict.localSnapshotHash == activeHash ? conflict.remoteSnapshotHash : conflict.localSnapshotHash
        guard let stashedDrawing = ConflictVersionStore.load(notebookID: notebook.id, pageID: pageID, hash: stashedHash) else { return }

        guard let newHash = try? NotebookPackage.persistPage(
            package: packageURL, pageID: pageID, drawing: stashedDrawing,
            annotations: notebook.page(for: pageID)?.meta.annotations ?? []
        ) else { return }
        try? journalStore.appendEntry(notebookID: notebook.id, pageID: pageID.uuidString, contentHash: newHash)
        try? ConflictVersionStore.discard(notebookID: notebook.id, pageID: pageID, hash: stashedHash)

        notebook.page(for: pageID)?.drawing = stashedDrawing
        notebook.page(for: pageID)?.setConflict(nil)
    }

    /// "Keep both as two pages": materialize the stashed version as a brand-new page
    /// inserted right after the original, then clear the conflict. This is a
    /// notebook-structure edit, so it goes through `NotebookUndoStack`.
    static func keepBothAsTwoPages(
        notebook: Notebook, pageID: UUID, journalStore: JournalStore, packageURL: URL
    ) {
        guard let conflict = notebook.page(for: pageID)?.conflict else { return }
        let activeHash = currentHash(notebook: notebook, pageID: pageID)
        let stashedHash = conflict.localSnapshotHash == activeHash ? conflict.remoteSnapshotHash : conflict.localSnapshotHash
        guard let stashedDrawing = ConflictVersionStore.load(notebookID: notebook.id, pageID: pageID, hash: stashedHash) else { return }

        let newPageID = UUID()
        guard let newHash = try? NotebookPackage.persistPage(
            package: packageURL, pageID: newPageID, drawing: stashedDrawing, annotations: []
        ) else { return }
        try? journalStore.appendEntry(notebookID: notebook.id, pageID: newPageID.uuidString, contentHash: newHash)

        let insertIndex = (notebook.pageOrder.firstIndex(of: pageID) ?? notebook.pageOrder.count - 1) + 1
        notebook.undoStack.perform(NotebookStructureCommand(
            estimatedByteCost: stashedDrawing.dataRepresentation().count,
            performUndo: { [weak notebook] in notebook?.removePage(newPageID) },
            performRedo: { [weak notebook] in notebook?.insertPage(newPageID, at: insertIndex) }
        ))
        try? NotebookPackage.writeManifest(notebook.manifest, package: packageURL)
        try? journalStore.appendEntry(notebookID: notebook.id, pageID: JournalPageID.manifest, contentHash: ContentHash.sha256Hex(of: (try? ManifestCoding.encode(notebook.manifest)) ?? Data()))

        try? ConflictVersionStore.discard(notebookID: notebook.id, pageID: pageID, hash: stashedHash)
        notebook.page(for: pageID)?.setConflict(nil)
    }

    private static func currentHash(notebook: Notebook, pageID: UUID) -> String? {
        notebook.page(for: pageID)?.meta.contentHash
    }
}
