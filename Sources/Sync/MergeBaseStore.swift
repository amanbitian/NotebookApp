import Foundation
import PencilKit

/// Manages `merge-base/<pageUUID>.data` (§3.2, §7.2): the last-synced `drawing.data`
/// bytes, snapshotted at the moment a page transitions from clean to dirty. This is
/// the common ancestor a 3-way merge needs to distinguish "deleted in one branch" from
/// "added in the other" — a 2-way merge cannot make that distinction and resurrects
/// deletions.
enum MergeBaseStore {

    /// Snapshots the page's current on-disk (i.e. last-synced) bytes as its merge base,
    /// but only if one doesn't already exist — a page can go dirty→synced→dirty several
    /// times before its next remote conflict check, and the base must stay pinned to
    /// the version that was last actually synced, not the most recent dirty transition.
    /// Must be called before the autosave pipeline overwrites `drawing.data` with the
    /// new dirty content, i.e. at the clean→dirty transition itself.
    static func snapshotIfNeeded(notebookID: UUID, pageID: UUID, packageURL: URL) throws {
        let baseURL = try PackageLayout.mergeBaseURL(notebookID: notebookID, pageID: pageID)
        guard !FileManager.default.fileExists(atPath: baseURL.path) else { return }
        let drawingURL = PackageLayout.drawingDataURL(package: packageURL, pageID: pageID)
        guard let data = try? Data(contentsOf: drawingURL) else { return }
        try AtomicFileWriter.write(data, to: baseURL)
    }

    static func load(notebookID: UUID, pageID: UUID) -> PKDrawing? {
        guard let url = try? PackageLayout.mergeBaseURL(notebookID: notebookID, pageID: pageID),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? PKDrawing(data: data)
    }

    /// Clears the merge base once a page is confirmed synced — the next dirty
    /// transition will snapshot a fresh base from the newly-synced version.
    static func clear(notebookID: UUID, pageID: UUID) throws {
        guard let url = try? PackageLayout.mergeBaseURL(notebookID: notebookID, pageID: pageID) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
