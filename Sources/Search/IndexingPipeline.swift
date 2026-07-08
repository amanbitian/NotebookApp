import Foundation
import PDFKit
import PencilKit
import UIKit
import Vision

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
    // NSCache rather than a plain dictionary: a long session that indexes many
    // different notebooks would otherwise grow this unboundedly (§11's memory
    // ceiling applies here too) — NSCache evicts under memory pressure instead.
    private let pdfDocumentCache = NSCache<NSURL, PDFDocument>()

    /// v1.2 feature flag (§13): handwriting OCR ships later. Flipping this on is the
    /// only change needed once Vision-based OCR is wired up — everything else in this
    /// pipeline (enqueue, dedup via contentHash, FTS upsert) already exists from v1.0.
    var ocrEnabled = true

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
        if (try? indexStore.isIndexed(pageID: job.pageID, contentHash: job.contentHash)) == true {
            return
        }

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
              let pdfDocument = pdfDocument(for: job.packageURL),
              let pdfPage = pdfDocument.page(at: pdfPageIndex),
              let text = pdfPage.string, !text.isEmpty else {
            return nil
        }
        return text
    }

    private func pdfDocument(for packageURL: URL) -> PDFDocument? {
        let sourceURL = PackageLayout.sourcePDFURL(package: packageURL) as NSURL
        if let cached = pdfDocumentCache.object(forKey: sourceURL) {
            return cached
        }
        guard let document = PDFDocument(url: sourceURL as URL) else { return nil }
        pdfDocumentCache.setObject(document, forKey: sourceURL)
        return document
    }

    private func runHandwritingOCR(job: IndexingJob) -> [String] {
        guard let drawingData = try? Data(contentsOf: PackageLayout.drawingDataURL(package: job.packageURL, pageID: job.pageID)),
              let drawing = try? PKDrawing(data: drawingData),
              !drawing.strokes.isEmpty else {
            return []
        }

        let drawingBounds = drawing.bounds.insetBy(dx: -24, dy: -24)
        guard drawingBounds.width > 1, drawingBounds.height > 1 else { return [] }

        let transparentInk = drawing.image(from: drawingBounds, scale: 2)
        let renderer = UIGraphicsImageRenderer(size: transparentInk.size)
        let ocrImage = renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: transparentInk.size))
            transparentInk.draw(in: CGRect(origin: .zero, size: transparentInk.size))
        }
        guard let cgImage = ocrImage.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return request.results?.compactMap { observation in
            observation.topCandidates(1).first?.string
        } ?? []
    }

    /// §8, §10: a full rebuild ("index.sqlite missing or corrupt") is just
    /// re-enqueueing every page — `IndexStore.rebuildFromScratch` clears the tables
    /// first so stale entries can't linger.
    func rebuildAll(jobs: [IndexingJob]) {
        try? indexStore.rebuildFromScratch()
        jobs.forEach(enqueue)
    }
}
