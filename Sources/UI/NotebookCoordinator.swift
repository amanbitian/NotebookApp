import Foundation
import PencilKit

/// Wires together everything an open notebook needs: the autosave pipeline, journal,
/// sync engine, and indexing pipeline. One instance per open notebook — created when
/// a notebook is opened from the library, discarded when it's closed.
@MainActor
final class NotebookCoordinator: ObservableObject {
    let notebook: Notebook
    let journalStore: JournalStore
    let autosave: AutosavePipeline
    let syncEngine: SyncEngine
    let indexingPipeline: IndexingPipeline
    private(set) var driveBackupScheduler: GoogleDriveBackupScheduler?

    init(notebook: Notebook, indexStore: IndexStore) throws {
        self.notebook = notebook
        self.journalStore = try JournalStore(notebookID: notebook.id)
        self.autosave = AutosavePipeline(notebookID: notebook.id, packageURL: notebook.packageURL, journalStore: journalStore)
        self.syncEngine = SyncEngine(notebookID: notebook.id, journalStore: journalStore)
        self.indexingPipeline = IndexingPipeline(indexStore: indexStore)

        syncEngine.notebook = notebook

        // Startup reconciliation (§10): if the app crashed after a file write but
        // before its journal row landed, catch the journal up to on-disk truth before
        // anything else runs.
        try? journalStore.reconcileOnLaunch(notebookID: notebook.id, onDiskHashes: Self.onDiskHashes(notebook: notebook))

        if let containerURL = ICloudSyncAdapter.ubiquityContainerURL(),
           notebook.packageURL.path.hasPrefix(containerURL.path) {
            syncEngine.registerTwoWay(ICloudSyncAdapter(), packageURL: notebook.packageURL)
        }

        autosave.onPageFlushed = { [weak self] page, hash in
            self?.handleFlushed(page: page, hash: hash)
        }
    }

    func configureGoogleDriveBackup(
        tokenProvider: GoogleAuthTokenProviding,
        includeZippedPackage: Bool = false,
        debounceInterval: TimeInterval = 15 * 60
    ) {
        let adapter = GoogleDriveAdapter(tokenProvider: tokenProvider)
        driveBackupScheduler = GoogleDriveBackupScheduler(
            adapter: adapter,
            packageURL: notebook.packageURL,
            pageOrder: notebook.pageOrder,
            options: GoogleDriveBackupScheduler.Options(
                includeFlattenedPDF: true,
                includeZippedPackage: includeZippedPackage,
                debounceInterval: debounceInterval
            )
        )
    }

    func backupToGoogleDriveNow() async {
        driveBackupScheduler?.update(pageOrder: notebook.pageOrder)
        await driveBackupScheduler?.backupNow()
    }

    private static func onDiskHashes(notebook: Notebook) -> [String: String] {
        var result: [String: String] = [:]
        for pageID in notebook.pageOrder {
            let metaURL = PackageLayout.pageMetaURL(package: notebook.packageURL, pageID: pageID)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? ManifestCoding.decoder.decode(PageMeta.self, from: data) else {
                continue
            }
            result[pageID.uuidString] = meta.contentHash
        }
        return result
    }

    /// Loads a page's files into memory if it isn't already (§11: "Open = manifest +
    /// visible pages only" — pages are not all loaded up front).
    func openPage(_ pageID: UUID) throws -> Page {
        if let existing = notebook.page(for: pageID) { return existing }
        let page = try NotebookPackage.loadPage(package: notebook.packageURL, pageID: pageID)
        notebook.registerLoaded(page)
        return page
    }

    /// Cheap, no I/O. Call from `canvasViewDrawingDidChange`.
    func handleDrawingChanged(page: Page) {
        autosave.handleDrawingChanged(page: page)
    }

    func handlePencilLift(page: Page) {
        autosave.handlePencilLift(page: page)
    }

    /// Call after any annotation insert/move/delete (e.g. inserting an image) — these
    /// don't touch `page.drawing`, so they need their own path into autosave (§5).
    func handleAnnotationsChanged(page: Page) {
        autosave.handleAnnotationsChanged(page: page)
    }

    /// Encodes picked image bytes into the annotation payload and returns the
    /// value to store as the new annotation's `content`.
    func saveImage(pageID: UUID, data: Data) throws -> String {
        try NotebookPackage.saveImage(package: notebook.packageURL, pageID: pageID, data: data)
    }

    func loadImage(pageID: UUID, fileName: String) -> Data? {
        try? NotebookPackage.loadImage(package: notebook.packageURL, pageID: pageID, fileName: fileName)
    }

    /// Call on page exit / app backgrounding — bypasses the debounce (§5 note 4).
    func flushAllImmediately() async {
        await autosave.flushAllDirtyPagesImmediately(in: notebook)
        for cloud in syncEngine.activeClouds {
            await syncEngine.syncUploads(to: cloud, packageURL: notebook.packageURL)
        }
    }

    private func handleFlushed(page: Page, hash: String) {
        Task {
            for cloud in syncEngine.activeClouds {
                await syncEngine.syncUploads(to: cloud, packageURL: notebook.packageURL)
            }
        }

        driveBackupScheduler?.update(pageOrder: notebook.pageOrder)
        driveBackupScheduler?.scheduleAfterEdit()

        let pdfPageIndex = notebook.pageIndex(for: page.id)
        indexingPipeline.enqueue(IndexingJob(
            notebookID: notebook.id, pageID: page.id, contentHash: hash,
            packageURL: notebook.packageURL, pdfPageIndex: pdfPageIndex
        ))
    }
}
