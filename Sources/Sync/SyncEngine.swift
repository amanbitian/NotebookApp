import Foundation
import PencilKit

/// Orchestrates the sync engine described in §6: diffs the journal against each
/// cloud's checkpoint to compute an upload set, drives the per-(cloud, page) state
/// machine, and — for two-way clouds — routes incoming remote changes through
/// `ConflictResolver`.
@MainActor
final class SyncEngine {
    private let notebookID: UUID
    private let journalStore: JournalStore
    private var pushAdapters: [SyncCloud: any PushSyncAdapter] = [:]
    private var stateMachines: [SyncCloud: SyncStateMachine] = [:]

    /// v1.1 flips this on for pure-ink pages once the merge path is validated (§7.4).
    var mergeEnabled = false

    weak var notebook: Notebook?

    init(notebookID: UUID, journalStore: JournalStore) {
        self.notebookID = notebookID
        self.journalStore = journalStore
    }

    func register(_ adapter: any PushSyncAdapter) {
        pushAdapters[adapter.cloud] = adapter
        stateMachines[adapter.cloud] = SyncStateMachine(journalStore: journalStore, cloud: adapter.cloud, notebookID: notebookID)
    }

    func registerTwoWay(_ adapter: any TwoWaySyncAdapter, packageURL: URL) {
        register(adapter)
        adapter.startObservingChanges(notebookID: notebookID, packageURL: packageURL) { [weak self] change in
            Task { @MainActor in
                await self?.handleIncomingRemoteChange(change, cloud: adapter.cloud, packageURL: packageURL)
            }
        }
    }

    var activeClouds: [SyncCloud] {
        Array(pushAdapters.keys)
    }

    // MARK: - Upload path (§6.1, §6.2)

    /// Diffs latest journal hash per page against `cloud`'s checkpoint, pushes what
    /// changed, and advances each page's per-cloud state. Call periodically and after
    /// every successful autosave flush.
    func syncUploads(to cloud: SyncCloud, packageURL: URL) async {
        guard let adapter = pushAdapters[cloud], let stateMachine = stateMachines[cloud] else { return }
        guard let pending = try? journalStore.pendingUploads(cloud: cloud, notebookID: notebookID), !pending.isEmpty else { return }

        for item in pending {
            do {
                try advanceToUploading(stateMachine: stateMachine, pageID: item.pageID)
                if item.pageID == JournalPageID.manifest {
                    try await adapter.uploadManifest(notebookID: notebookID, packageURL: packageURL)
                } else {
                    try await adapter.uploadPage(notebookID: notebookID, packageURL: packageURL, pageID: item.pageID, contentHash: item.contentHash)
                }
                try journalStore.setCheckpoint(
                    cloud: cloud, notebookID: notebookID, pageID: item.pageID,
                    syncedHash: item.contentHash, syncedSeq: item.seq
                )
                try stateMachine.transition(pageID: item.pageID, to: .synced)

                if cloud == .icloud, let pageUUID = UUID(uuidString: item.pageID) {
                    try? MergeBaseStore.clear(notebookID: notebookID, pageID: pageUUID)
                }
            } catch {
                // Leave the page eligible for retry on the next pass rather than
                // wedging it in `.uploading` forever.
                try? stateMachine.transition(pageID: item.pageID, to: .dirty)
            }
        }

        try? journalStore.compact(notebookID: notebookID, activeClouds: activeClouds)
    }

    private func advanceToUploading(stateMachine: SyncStateMachine, pageID: String) throws {
        let current = try stateMachine.currentState(pageID: pageID)
        if current != .dirty {
            try stateMachine.transition(pageID: pageID, to: .dirty)
        }
        try stateMachine.transition(pageID: pageID, to: .uploading)
    }

    // MARK: - Download / conflict path (§6.3, §7)

    private func handleIncomingRemoteChange(_ change: RemotePageChange, cloud: SyncCloud, packageURL: URL) async {
        guard let pageUUID = UUID(uuidString: change.pageID) else { return }

        guard let localMeta = readLocalMeta(packageURL: packageURL, pageID: pageUUID),
              let localDrawing = readLocalDrawing(packageURL: packageURL, pageID: pageUUID) else {
            return
        }

        let localHasUnsyncedChanges = hasUnsyncedChanges(cloud: cloud, pageID: change.pageID)

        let decision = ConflictResolver.decide(
            notebookID: notebookID,
            pageID: pageUUID,
            localHash: localMeta.contentHash,
            remoteHash: change.remoteMeta.contentHash,
            localHasUnsyncedChanges: localHasUnsyncedChanges,
            localDrawing: localDrawing,
            remoteDrawing: change.remoteDrawing,
            mergeEnabled: mergeEnabled
        )

        switch decision {
        case .applyRemote:
            applyIncomingDrawing(
                change.remoteDrawing, annotations: change.remoteMeta.annotations,
                pageID: pageUUID, packageURL: packageURL, cloud: cloud,
                sourceDeviceID: change.remoteMeta.deviceID,
                sourceChangedAt: change.remoteMeta.lastModified
            )

        case .applyMerged(let merged):
            applyIncomingDrawing(
                merged, annotations: localMeta.annotations,
                pageID: pageUUID, packageURL: packageURL, cloud: cloud,
                sourceDeviceID: DeviceIdentity.current, sourceChangedAt: Date()
            )

        case .bothVersionsKept(let conflict):
            resolveByKeepingBoth(
                conflict: conflict, localMeta: localMeta, localDrawing: localDrawing,
                remote: change, pageID: pageUUID, packageURL: packageURL
            )
        }
    }

    private func hasUnsyncedChanges(cloud: SyncCloud, pageID: String) -> Bool {
        guard let latest = try? journalStore.latestEntry(notebookID: notebookID, pageID: pageID) else {
            return false
        }
        guard let checkpoint = try? journalStore.checkpoint(cloud: cloud, notebookID: notebookID, pageID: pageID) else {
            // Never synced to this cloud but has local history: treat as unsynced.
            return true
        }
        return (latest.seq ?? 0) > checkpoint.syncedSeq
    }

    private func applyIncomingDrawing(
        _ drawing: PKDrawing, annotations: [Annotation], pageID: UUID, packageURL: URL, cloud: SyncCloud,
        sourceDeviceID: String, sourceChangedAt: Date
    ) {
        guard let meta = try? NotebookPackage.persistPage(package: packageURL, pageID: pageID, drawing: drawing, annotations: annotations) else {
            return
        }
        try? journalStore.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: meta.contentHash, deviceID: sourceDeviceID, changedAt: sourceChangedAt)
        if let latestSeq = try? journalStore.latestEntry(notebookID: notebookID, pageID: pageID.uuidString)?.seq {
            try? journalStore.setCheckpoint(cloud: cloud, notebookID: notebookID, pageID: pageID.uuidString, syncedHash: meta.contentHash, syncedSeq: latestSeq)
        }
        try? MergeBaseStore.clear(notebookID: notebookID, pageID: pageID)

        if let page = notebook?.page(for: pageID) {
            page.drawing = drawing
            page.meta = meta
            page.clearDirty()
            page.setConflict(nil)
        }
    }

    private func resolveByKeepingBoth(
        conflict: PageConflict, localMeta: PageMeta, localDrawing: PKDrawing,
        remote: RemotePageChange, pageID: UUID, packageURL: URL
    ) {
        let remoteIsNewer = remote.remoteMeta.lastModified > localMeta.lastModified
        if remoteIsNewer {
            try? ConflictVersionStore.store(notebookID: notebookID, pageID: pageID, hash: localMeta.contentHash, drawing: localDrawing)
            let activeMeta = try? NotebookPackage.persistPage(package: packageURL, pageID: pageID, drawing: remote.remoteDrawing, annotations: remote.remoteMeta.annotations)
            if let page = notebook?.page(for: pageID) {
                page.drawing = remote.remoteDrawing
                if let activeMeta {
                    page.meta = activeMeta
                }
            }
        } else {
            try? ConflictVersionStore.store(notebookID: notebookID, pageID: pageID, hash: remote.remoteMeta.contentHash, drawing: remote.remoteDrawing)
            // Local page stays active; nothing to overwrite on disk.
        }
        notebook?.page(for: pageID)?.setConflict(conflict)
    }

    private func readLocalMeta(packageURL: URL, pageID: UUID) -> PageMeta? {
        guard let data = try? Data(contentsOf: PackageLayout.pageMetaURL(package: packageURL, pageID: pageID)) else { return nil }
        return try? ManifestCoding.decoder.decode(PageMeta.self, from: data)
    }

    private func readLocalDrawing(packageURL: URL, pageID: UUID) -> PKDrawing? {
        guard let data = try? Data(contentsOf: PackageLayout.drawingDataURL(package: packageURL, pageID: pageID)) else { return nil }
        return try? PKDrawing(data: data)
    }
}
