import Foundation
import PDFKit

struct IndexingJob {
    let notebookID: UUID
    let pageID: UUID
    let contentHash: String
    let packageURL: URL
    /// Index into `source.pdf`, if this page corresponds 1:1 with an original PDF
    /// page (true for everything `ImportJob` creates today). `nil` for pages with no
    /// backing PDF page.
    let pdfPageIndex: Int?
}

/// Background, low-priority consumer of page writes (§8). Search is a consumer of
/// content, never a participant in the write path — autosave must not block on
/// indexing, ever, so this queue is fed fire-and-forget.
final class IndexingPipeline {
    private let indexStore: IndexStore
    private let queue = DispatchQueue(label: "com.amancisodia.NotebookApp.indexing", qos: .background)

    /// v1.2 feature flag (§13): handwriting OCR ships later. Flipping this on is the
    /// only change needed once Vision-based OCR is wired up — everything else in this
    /// pipeline (enqueue, dedup via contentHash, FTS upsert) already exists from v1.0.
    var ocrEnabled = false

    init(indexStore: IndexStore) {
        self.indexStore = indexStore
    }

    /// Call right after a journal row is appended for a page write (§8: "page write
    /// committed (journal row exists) → enqueue indexing job").
    func enqueue(_ job: IndexingJob) {
        queue.async { [weak self] in
            self?.process(job)
        }
    }

    private func process(_ job: IndexingJob) {
        var textParts: [String] = []
        textParts.append(contentsOf: extractAnnotationText(job: job))
        if let pdfText = extractPDFLayerText(job: job) {
            textParts.append(pdfText)
        }
        if ocrEnabled {
            textParts.append(contentsOf: runHandwritingOCR(job: job))
        }

        let combined = textParts.joined(separator: "\n")
        guard !combined.isEmpty else { return }
        // Keyed by (pageID, contentHash) — idempotent and self-healing: a stale entry
        // is simply overwritten on the next pass (§8).
        try? indexStore.upsert(notebookID: job.notebookID, pageID: job.pageID, contentHash: job.contentHash, text: combined)
    }

    private func extractAnnotationText(job: IndexingJob) -> [String] {
        guard let metaData = try? Data(contentsOf: PackageLayout.pageMetaURL(package: job.packageURL, pageID: job.pageID)),
              let meta = try? ManifestCoding.decoder.decode(PageMeta.self, from: metaData) else {
            return []
        }
        return meta.annotations.filter { $0.kind == .text }.map(\.content)
    }

    private func extractPDFLayerText(job: IndexingJob) -> String? {
        guard let pdfPageIndex = job.pdfPageIndex,
              let pdfDocument = PDFDocument(url: PackageLayout.sourcePDFURL(package: job.packageURL)),
              let pdfPage = pdfDocument.page(at: pdfPageIndex),
              let text = pdfPage.string, !text.isEmpty else {
            return nil
        }
        return text
    }

    /// v1.2 (§8, §13): on-device handwriting OCR via Apple's Vision framework — no
    /// server, no privacy exposure, consistent with the no-backend v1 architecture.
    /// Left as a stub: rasterizing `PKDrawing` to a `CGImage` for `VNRecognizeTextRequest`
    /// input needs `UIGraphicsImageRenderer`, which is straightforward but out of scope
    /// until `ocrEnabled` flips on.
    private func runHandwritingOCR(job: IndexingJob) -> [String] {
        []
    }

    /// §8, §10: a full rebuild ("index.sqlite missing or corrupt") is just
    /// re-enqueueing every page — `IndexStore.rebuildFromScratch` clears the tables
    /// first so stale entries can't linger.
    func rebuildAll(jobs: [IndexingJob]) {
        try? indexStore.rebuildFromScratch()
        jobs.forEach(enqueue)
    }
}
