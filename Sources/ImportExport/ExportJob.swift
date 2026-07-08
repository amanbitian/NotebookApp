import Foundation
import PDFKit
import PencilKit
import UIKit

enum ExportError: Error {
    case sourceUnreadable
}

/// Flattened-PDF export (§9): cancellable, progress-reporting, background QoS. Memory
/// rule: one page in flight at a time, streamed to disk — a 300-page annotated export
/// must run in bounded memory on the oldest supported iPad (§11) and survive
/// backgrounding via a background task assertion.
@MainActor
final class ExportJob: ObservableObject {
    enum State: Equatable {
        case notStarted
        case inProgress(completed: Int, total: Int)
        case completed(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .notStarted
    private var task: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func exportFlattenedPDF(pageOrder: [UUID], packageURL: URL, exportScale: CGFloat = 2.0) {
        task?.cancel()
        state = .inProgress(completed: 0, total: pageOrder.count)
        beginBackgroundTask()

        task = Task.detached(priority: .utility) { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endBackgroundTask() } }
            do {
                let outputURL = try Self.render(
                    pageOrder: pageOrder, packageURL: packageURL, exportScale: exportScale,
                    progress: { completed in
                        Task { @MainActor [weak self] in self?.setProgress(completed: completed, total: pageOrder.count) }
                    },
                    isCancelled: { Task.isCancelled }
                )
                await MainActor.run { self?.state = .completed(outputURL) }
            } catch is CancellationError {
                await MainActor.run { self?.state = .cancelled }
            } catch {
                await MainActor.run { self?.state = .failed(String(describing: error)) }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func setProgress(completed: Int, total: Int) {
        guard case .inProgress = state else { return }
        state = .inProgress(completed: completed, total: total)
    }

    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "NotebookExport") { [weak self] in
            // Out of background time: cancel so the render loop exits cleanly at the
            // next page boundary rather than being killed mid-write.
            self?.task?.cancel()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    nonisolated private static func render(
        pageOrder: [UUID], packageURL: URL, exportScale: CGFloat,
        progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool
    ) throws -> URL {
        guard let sourcePDF = PDFDocument(url: PackageLayout.sourcePDFURL(package: packageURL)) else {
            throw ExportError.sourceUnreadable
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        try renderer.writePDF(to: outputURL) { context in
            for (index, pageID) in pageOrder.enumerated() {
                if isCancelled() { break }
                guard let sourcePage = sourcePDF.page(at: index) else { continue }
                renderFlattenedPage(sourcePage: sourcePage, pageID: pageID, packageURL: packageURL, exportScale: exportScale, context: context)
                progress(index + 1)
            }
        }

        if isCancelled() {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
        return outputURL
    }

    nonisolated private static func renderFlattenedPage(
        sourcePage: PDFPage, pageID: UUID, packageURL: URL, exportScale: CGFloat, context: UIGraphicsPDFRendererContext
    ) {
        let pageBounds = sourcePage.bounds(for: .mediaBox)
        context.beginPage(withBounds: pageBounds, pageInfo: [:])

        let cgContext = context.cgContext
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: pageBounds.height)
        cgContext.scaleBy(x: 1, y: -1)
        sourcePage.draw(with: .mediaBox, to: cgContext)
        cgContext.restoreGState()

        if let drawingData = try? Data(contentsOf: PackageLayout.drawingDataURL(package: packageURL, pageID: pageID)),
           let drawing = try? PKDrawing(data: drawingData), !drawing.strokes.isEmpty {
            let image = drawing.image(from: pageBounds, scale: exportScale)
            image.draw(in: pageBounds)
        }

        if let metaData = try? Data(contentsOf: PackageLayout.pageMetaURL(package: packageURL, pageID: pageID)),
           let meta = try? ManifestCoding.decoder.decode(PageMeta.self, from: metaData) {
            for annotation in meta.annotations where annotation.kind == .text {
                drawTextAnnotation(annotation, in: cgContext)
            }
        }
    }

    nonisolated private static func drawTextAnnotation(_ annotation: Annotation, in context: CGContext) {
        let attributed = NSAttributedString(string: annotation.content, attributes: [.font: UIFont.systemFont(ofSize: 12)])
        UIGraphicsPushContext(context)
        attributed.draw(in: annotation.frame)
        UIGraphicsPopContext()
    }
}
