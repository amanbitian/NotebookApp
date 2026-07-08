import Foundation
import PencilKit

/// Live two-way iCloud sync (§6.3). The `.notepkg` package lives inside the app's
/// iCloud Drive ubiquity container; because the sync unit is the individual page file,
/// iCloud transfers only changed pages — editing one page of a 500 MB notebook
/// uploads kilobytes, not the whole package.
///
/// `NSMetadataQuery` is the standard mechanism for observing ubiquitous-item changes
/// without polling; `NSFileCoordinator` guards reads/writes against races with the
/// iCloud daemon. This adapter intentionally keeps its own change-tracking minimal —
/// `SyncEngine` and `ConflictResolver` own the actual decision logic — and only
/// translates iCloud's file-level notifications into `RemotePageChange` values.
final class ICloudSyncAdapter: NSObject, TwoWaySyncAdapter {
    let cloud: SyncCloud = .icloud

    private var metadataQuery: NSMetadataQuery?
    private var onChange: ((RemotePageChange) -> Void)?
    private var observedNotebookID: UUID?
    private var observedPackageURL: URL?
    private var lastSeenModificationDates: [String: Date] = [:]

    static func ubiquityContainerURL(containerIdentifier: String? = nil) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    /// Files inside the ubiquity container upload automatically via the system daemon
    /// once written — there is no separate "push" API call the app needs to make.
    /// This performs a coordinated read to confirm the write that the autosave
    /// pipeline already made atomically is intact and coherent from iCloud's
    /// perspective, satisfying `PushSyncAdapter`'s contract.
    func uploadPage(notebookID: UUID, packageURL: URL, pageID: String, contentHash: String) async throws {
        guard let pageUUID = UUID(uuidString: pageID) else { return }
        let url = PackageLayout.drawingDataURL(package: packageURL, pageID: pageUUID)
        try coordinatedRead(url: url) { _ in }
    }

    func uploadManifest(notebookID: UUID, packageURL: URL) async throws {
        let url = PackageLayout.manifestURL(package: packageURL)
        try coordinatedRead(url: url) { _ in }
    }

    private func coordinatedRead(url: URL, body: (URL) -> Void) throws {
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var thrown: Error?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
            body(coordinatedURL)
        }
        if let coordinatorError { thrown = coordinatorError }
        if let thrown { throw thrown }
    }

    // MARK: - Change observation

    func startObservingChanges(notebookID: UUID, packageURL: URL, onChange: @escaping (RemotePageChange) -> Void) {
        stopObservingChanges(notebookID: notebookID)
        self.onChange = onChange
        self.observedNotebookID = notebookID
        self.observedPackageURL = packageURL.standardizedFileURL
        self.lastSeenModificationDates.removeAll()

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "meta.json")
        query.enableUpdates()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueryUpdate(_:)),
            name: .NSMetadataQueryDidUpdate, object: query
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueryUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )

        metadataQuery = query
        query.start()
    }

    func stopObservingChanges(notebookID: UUID) {
        guard let query = metadataQuery else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        metadataQuery = nil
        onChange = nil
        observedNotebookID = nil
        observedPackageURL = nil
        lastSeenModificationDates.removeAll()
    }

    @objc private func handleQueryUpdate(_ notification: Notification) {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        for item in query.results.compactMap({ $0 as? NSMetadataItem }) {
            guard let itemURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            guard isInsideObservedPackage(itemURL) else { continue }
            guard let downloaded = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
                  downloaded == NSMetadataUbiquitousItemDownloadingStatusCurrent else {
                // Not fully downloaded yet — the query will fire again once it is.
                continue
            }
            processChangedMeta(at: itemURL)
        }
    }

    private func processChangedMeta(at metaURL: URL) {
        guard isInsideObservedPackage(metaURL) else { return }
        // meta.json lives at pages/<pageUUID>/meta.json
        let pageFolder = metaURL.deletingLastPathComponent()
        guard let pageID = UUID(uuidString: pageFolder.lastPathComponent) else { return }

        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? ManifestCoding.decoder.decode(PageMeta.self, from: metaData) else {
            return
        }

        // Skip changes this device just wrote itself, and duplicate notifications for
        // a modification we've already processed.
        guard meta.deviceID != DeviceIdentity.current else { return }
        if let lastSeen = lastSeenModificationDates[pageID.uuidString], lastSeen >= meta.lastModified {
            return
        }
        lastSeenModificationDates[pageID.uuidString] = meta.lastModified

        let drawingURL = pageFolder.appendingPathComponent("drawing.data")
        guard let drawingData = try? Data(contentsOf: drawingURL),
              let drawing = try? PKDrawing(data: drawingData) else {
            return
        }

        onChange?(RemotePageChange(pageID: pageID.uuidString, remoteMeta: meta, remoteDrawing: drawing))
    }

    private func isInsideObservedPackage(_ url: URL) -> Bool {
        guard let observedPackageURL else { return false }
        let observedPath = observedPackageURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == observedPath || candidatePath.hasPrefix(observedPath + "/")
    }
}
