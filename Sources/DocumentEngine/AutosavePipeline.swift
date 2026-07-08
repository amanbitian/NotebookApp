import Foundation
import PencilKit

/// Implements the write path from §5. Never serializes on the main thread and never
/// serializes inside `canvasViewDrawingDidChange` itself — that callback can fire many
/// times per second during fast writing, so it only flips an in-memory dirty flag and
/// (re)starts a debounce timer.
///
/// The ordering invariant this type exists to protect: the journal row is appended
/// strictly after the atomic file write succeeds (§2). Crash recovery depends on it.
@MainActor
final class AutosavePipeline {
    private let notebookID: UUID
    private let packageURL: URL
    private let journalStore: JournalStore
    private let debounceInterval: TimeInterval
    private let pencilLiftIdleFlushThreshold: TimeInterval

    private let backgroundQueue = DispatchQueue(label: "com.amancisodia.NotebookApp.autosave", qos: .utility)

    private var debounceTimers: [UUID: Timer] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var retryBackoffSeconds: [UUID: TimeInterval] = [:]
    private var lastActivity: [UUID: Date] = [:]

    /// Fired after a page's drawing + meta are atomically written and its journal row
    /// lands. Wired by the owning coordinator to trigger sync uploads and indexing.
    var onPageFlushed: ((Page, String) -> Void)?

    init(
        notebookID: UUID,
        packageURL: URL,
        journalStore: JournalStore,
        debounceInterval: TimeInterval = 2.5,
        pencilLiftIdleFlushThreshold: TimeInterval = 2.0
    ) {
        self.notebookID = notebookID
        self.packageURL = packageURL
        self.journalStore = journalStore
        self.debounceInterval = debounceInterval
        self.pencilLiftIdleFlushThreshold = pencilLiftIdleFlushThreshold
    }

    /// Cheap handler for `canvasViewDrawingDidChange`. No I/O beyond the merge-base
    /// snapshot below, which only fires once per clean→dirty transition and is a small
    /// file copy (§7.2) — everything else here is in-memory.
    func handleDrawingChanged(page: Page) {
        let wasClean = !page.isDirty
        page.markDirty()
        lastActivity[page.id] = Date()
        resetDebounce(for: page)

        if wasClean {
            // Snapshot the last-synced bytes as this page's merge base *before* the
            // debounced write below overwrites drawing.data (§7.2).
            try? MergeBaseStore.snapshotIfNeeded(notebookID: notebookID, pageID: page.id, packageURL: packageURL)
        }
    }

    /// Mitigates the "final debounce window is at risk" failure mode (§10): if the
    /// Pencil has been lifted and the page sat dirty past the idle threshold, flush
    /// now instead of waiting out the rest of the debounce window.
    func handlePencilLift(page: Page) {
        guard page.isDirty, let last = lastActivity[page.id] else { return }
        if Date().timeIntervalSince(last) >= pencilLiftIdleFlushThreshold {
            Task { await flush(page: page) }
        }
    }

    private func resetDebounce(for page: Page) {
        debounceTimers[page.id]?.invalidate()
        let timer = Timer(timeInterval: debounceInterval, repeats: false) { [weak self, weak page] _ in
            guard let self, let page else { return }
            Task { await self.flush(page: page) }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimers[page.id] = timer
    }

    /// Bypasses the debounce entirely — call on page exit and app backgrounding, the
    /// two moments users lose data in badly built apps (§5 note 4).
    func flushImmediately(page: Page) async {
        debounceTimers[page.id]?.invalidate()
        debounceTimers[page.id] = nil
        await flush(page: page)
    }

    func flushAllDirtyPagesImmediately(in notebook: Notebook) async {
        for pageID in notebook.pageOrder {
            guard let page = notebook.page(for: pageID), page.isDirty else { continue }
            await flushImmediately(page: page)
        }
    }

    private func flush(page: Page) async {
        guard page.isDirty else { return }

        // PKDrawing is a value type — this snapshot is safe to hand to a background
        // queue without locking the canvas (§5 note 2).
        let drawing = page.drawing
        let annotations = page.meta.annotations
        let pageID = page.id
        let packageURL = self.packageURL

        do {
            let hash = try await serializeAndWrite(packageURL: packageURL, pageID: pageID, drawing: drawing, annotations: annotations)

            // Journal entry strictly after the write succeeds — never before.
            try journalStore.appendEntry(notebookID: notebookID, pageID: pageID.uuidString, contentHash: hash)

            page.clearDirty()
            retryBackoffSeconds[pageID] = nil
            retryTasks[pageID]?.cancel()
            retryTasks[pageID] = nil

            // Journal row now exists — this is the hand-off point the design calls
            // out twice: sync picks up the dirty page in background (§2), and search
            // indexing enqueues its job only once the journal row exists (§8).
            onPageFlushed?(page, hash)
        } catch {
            scheduleRetry(page: page)
        }
    }

    private func serializeAndWrite(
        packageURL: URL, pageID: UUID, drawing: PKDrawing, annotations: [Annotation]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            backgroundQueue.async {
                do {
                    let hash = try NotebookPackage.persistPage(
                        package: packageURL, pageID: pageID, drawing: drawing, annotations: annotations
                    )
                    continuation.resume(returning: hash)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Dirty flag is retained (not cleared) on failure, and retried with exponential
    /// backoff, capped at 60s (§5 pipeline, §10 "dirty flag not cleared → rewrite on
    /// next launch").
    private func scheduleRetry(page: Page) {
        let pageID = page.id
        let nextDelay = min((retryBackoffSeconds[pageID] ?? 1) * 2, 60)
        retryBackoffSeconds[pageID] = nextDelay

        retryTasks[pageID]?.cancel()
        retryTasks[pageID] = Task { [weak self, weak page] in
            try? await Task.sleep(nanoseconds: UInt64(nextDelay * 1_000_000_000))
            guard let self, let page, !Task.isCancelled else { return }
            await self.flush(page: page)
        }
    }
}
