import Foundation
import PencilKit

/// A page or manifest change observed on a two-way cloud, ready for the conflict
/// resolution path (§7).
struct RemotePageChange {
    let pageID: String
    let remoteMeta: PageMeta
    let remoteDrawing: PKDrawing
}

/// Minimum contract every cloud adapter satisfies: it can push local changes up.
/// Google Drive (§6.4) implements only this — it is push-only by design, which is the
/// single constraint that eliminates three-way merge across two clouds.
protocol PushSyncAdapter: AnyObject {
    var cloud: SyncCloud { get }

    func uploadPage(notebookID: UUID, packageURL: URL, pageID: String, contentHash: String) async throws
    func uploadManifest(notebookID: UUID, packageURL: URL) async throws
}

/// iCloud additionally supports live two-way sync (§6.3): it observes remote changes
/// and feeds them back into the conflict resolution path.
protocol TwoWaySyncAdapter: PushSyncAdapter {
    func startObservingChanges(notebookID: UUID, packageURL: URL, onChange: @escaping (RemotePageChange) -> Void)
    func stopObservingChanges(notebookID: UUID)
}
