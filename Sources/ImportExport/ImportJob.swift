import Foundation
import PDFKit
import UIKit

enum ImportError: Error {
    case unsupportedFormat
}

/// Long-running, cancellable import with progress, never main-thread work (§9).
@MainActor
final class ImportJob: ObservableObject {
    enum State: Equatable {
        case notStarted
        case inProgress(completed: Int, total: Int)
        case completed(packageURL: URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .notStarted
    private var task: Task<Void, Never>?

    /// PDF → copy as `source.pdf`, create page UUIDs + manifest (§9). Fast, streaming
    /// page count — the heavy lifting is in `NotebookPackage.createFromPDF`.
    func importPDF(at sourceURL: URL, title: String, into rootDirectory: URL, cleanupSourceWhenFinished: Bool = false) {
        task?.cancel()
        state = .inProgress(completed: 0, total: 1)
        task = Task.detached(priority: .utility) { [weak self] in
            defer {
                if cleanupSourceWhenFinished {
                    try? FileManager.default.removeItem(at: sourceURL)
                }
            }
            do {
                let created = try NotebookPackage.createFromPDF(sourcePDFURL: sourceURL, title: title, in: rootDirectory)
                await self?.finish(.completed(packageURL: created.packageURL))
            } catch {
                await self?.finish(.failed(String(describing: error)))
            }
        }
    }

    /// Images → wrapped one per page (§9). Reuses the PDF import path by first
    /// rendering the images into a temporary single PDF, so the package format never
    /// needs to know an image-import code path exists.
    func importImages(_ images: [UIImage], title: String, into rootDirectory: URL) {
        task?.cancel()
        state = .inProgress(completed: 0, total: images.count)
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let tempPDF = try Self.renderImagesToTemporaryPDF(images: images) { completed in
                    Task { await self?.setProgress(completed: completed, total: images.count) }
                }
                defer { try? FileManager.default.removeItem(at: tempPDF) }

                if Task.isCancelled {
                    await self?.finish(.cancelled)
                    return
                }
                let created = try NotebookPackage.createFromPDF(sourcePDFURL: tempPDF, title: title, in: rootDirectory)
                await self?.finish(.completed(packageURL: created.packageURL))
            } catch {
                await self?.finish(.failed(String(describing: error)))
            }
        }
    }

    /// DOCX/PPTX (§9, v2.x): deferred. When added, conversion-to-PDF happens via a
    /// small backend (headless LibreOffice) and the result enters `importPDF` — the
    /// package format never learns about Office formats.
    func importOfficeDocument(at sourceURL: URL, title: String, into rootDirectory: URL) {
        state = .failed(String(describing: ImportError.unsupportedFormat))
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
    }

    private func finish(_ newState: State) {
        state = newState
    }

    private func setProgress(completed: Int, total: Int) {
        guard case .inProgress = state else { return }
        state = .inProgress(completed: completed, total: total)
    }

    nonisolated private static func renderImagesToTemporaryPDF(
        images: [UIImage], progress: @escaping (Int) -> Void
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, points
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        try renderer.writePDF(to: url) { context in
            for (index, image) in images.enumerated() {
                context.beginPage()
                image.draw(in: aspectFit(image.size, in: pageBounds))
                progress(index + 1)
            }
        }
        return url
    }

    nonisolated private static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2)
        return CGRect(origin: origin, size: fitted)
    }
}
