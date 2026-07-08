import Foundation
import PDFKit
import PencilKit

/// Reads and writes the `.notepkg` synced zone (§3.1). This is the only place that
/// touches package files directly — everything else (autosave, sync, import/export)
/// goes through here so the on-disk layout stays centralized in `PackageLayout`.
enum NotebookPackage {

    enum PackageError: Error {
        case manifestUnreadable(underlying: Error)
        case noPagesFoundForRecovery
        case sourceDocumentUnreadable
    }

    struct RecoveredManifest {
        let manifest: Manifest
        let wasRecovered: Bool
    }

    struct CreatedPackage {
        let manifest: Manifest
        let packageURL: URL
    }

    // MARK: - Creation

    /// Imports a PDF as a brand-new notebook package. `source.pdf` is written exactly
    /// once and never modified in place thereafter (§3.1, "Immutability of source.pdf").
    ///
    /// Returns the manifest and package URL rather than a live `Notebook` — this
    /// method does file I/O only and is called from background import tasks, while
    /// `Notebook` is `@MainActor` (it backs SwiftUI view state). Callers construct the
    /// `Notebook` on the main actor once this returns.
    @discardableResult
    static func createFromPDF(sourcePDFURL: URL, title: String, in rootDirectory: URL) throws -> CreatedPackage {
        let notebookID = UUID()
        let packageURL = rootDirectory.appendingPathComponent(sanitizedFolderName(title: title, id: notebookID))
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let destinationPDF = PackageLayout.sourcePDFURL(package: packageURL)
        try FileManager.default.copyItem(at: sourcePDFURL, to: destinationPDF)
        let sourceData = try Data(contentsOf: destinationPDF)
        let sourceHash = ContentHash.sha256Hex(of: sourceData)

        guard let pdfDocument = PDFDocument(url: destinationPDF) else {
            throw PackageError.sourceDocumentUnreadable
        }

        var pageOrder: [UUID] = []
        pageOrder.reserveCapacity(pdfDocument.pageCount)
        for _ in 0..<pdfDocument.pageCount {
            let pageID = UUID()
            pageOrder.append(pageID)
            try writeEmptyPage(package: packageURL, pageID: pageID)
        }

        let manifest = Manifest(
            notebookID: notebookID,
            title: title,
            source: Manifest.SourceDocument(type: .pdf, file: "source.pdf", sha256: sourceHash),
            pageOrder: pageOrder
        )
        try writeManifest(manifest, package: packageURL)

        return CreatedPackage(manifest: manifest, packageURL: packageURL)
    }

    private static func writeEmptyPage(package: URL, pageID: UUID) throws {
        let drawing = PKDrawing()
        let drawingData = drawing.dataRepresentation()
        try AtomicFileWriter.write(drawingData, to: PackageLayout.drawingDataURL(package: package, pageID: pageID))

        let meta = PageMeta(
            deviceID: DeviceIdentity.current,
            contentHash: ContentHash.sha256Hex(of: drawingData)
        )
        try AtomicFileWriter.writeJSON(meta, to: PackageLayout.pageMetaURL(package: package, pageID: pageID), encoder: ManifestCoding.encoder)
    }

    private static func sanitizedFolderName(title: String, id: UUID) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = title.components(separatedBy: invalidCharacters).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? id.uuidString : trimmed
        return "\(base).notepkg"
    }

    // MARK: - Manifest

    static func writeManifest(_ manifest: Manifest, package: URL) throws {
        try AtomicFileWriter.writeJSON(manifest, to: PackageLayout.manifestURL(package: package), encoder: ManifestCoding.encoder)
    }

    /// Loads the manifest, falling back to best-effort reconstruction if it's missing
    /// or unreadable (§4 rule 3). Degraded recovery beats total loss.
    static func loadManifest(package: URL) throws -> RecoveredManifest {
        let manifestURL = PackageLayout.manifestURL(package: package)
        if let data = try? Data(contentsOf: manifestURL), let manifest = try? ManifestCoding.decode(data) {
            return RecoveredManifest(manifest: manifest, wasRecovered: false)
        }
        let reconstructed = try reconstructManifest(package: package)
        return RecoveredManifest(manifest: reconstructed, wasRecovered: true)
    }

    /// Best-effort manifest reconstruction by enumerating `pages/*/meta.json` and
    /// sorting by `lastModified`, since each meta carries its own timestamp (§4 rule 3).
    /// Callers must flag the result to the user as "recovered — please verify page order."
    static func reconstructManifest(package: URL) throws -> Manifest {
        let pagesDir = PackageLayout.pagesDirectory(package: package)
        let pageFolders = (try? FileManager.default.contentsOfDirectory(
            at: pagesDir, includingPropertiesForKeys: nil
        )) ?? []

        struct Candidate { let id: UUID; let lastModified: Date }
        var candidates: [Candidate] = []
        for folder in pageFolders {
            guard let pageID = UUID(uuidString: folder.lastPathComponent) else { continue }
            let metaURL = PackageLayout.pageMetaURL(package: package, pageID: pageID)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? ManifestCoding.decoder.decode(PageMeta.self, from: data) else {
                continue
            }
            candidates.append(Candidate(id: pageID, lastModified: meta.lastModified))
        }
        guard !candidates.isEmpty else {
            throw PackageError.noPagesFoundForRecovery
        }
        candidates.sort { $0.lastModified < $1.lastModified }

        let sourceURL = PackageLayout.sourcePDFURL(package: package)
        let source: Manifest.SourceDocument
        if let sourceData = try? Data(contentsOf: sourceURL) {
            source = Manifest.SourceDocument(type: .pdf, file: "source.pdf", sha256: ContentHash.sha256Hex(of: sourceData))
        } else {
            source = Manifest.SourceDocument(type: .none, file: "", sha256: "")
        }

        return Manifest(
            title: "Recovered Notebook",
            source: source,
            pageOrder: candidates.map(\.id)
        )
    }

    // MARK: - Pages

    static func loadPage(package: URL, pageID: UUID) throws -> Page {
        let drawingData = try Data(contentsOf: PackageLayout.drawingDataURL(package: package, pageID: pageID))
        let metaData = try Data(contentsOf: PackageLayout.pageMetaURL(package: package, pageID: pageID))
        let drawing = try PKDrawing(data: drawingData)
        let meta = try ManifestCoding.decoder.decode(PageMeta.self, from: metaData)
        return Page(id: pageID, drawing: drawing, meta: meta)
    }

    /// Serializes and atomically writes a page's drawing + metadata. Returns the new
    /// content hash. Callers (the autosave pipeline) are responsible for appending the
    /// journal row *after* this returns successfully — never before (§5 pipeline).
    @discardableResult
    static func persistPage(package: URL, pageID: UUID, drawing: PKDrawing, annotations: [Annotation]) throws -> String {
        let drawingData = drawing.dataRepresentation()
        try AtomicFileWriter.write(drawingData, to: PackageLayout.drawingDataURL(package: package, pageID: pageID))

        let hash = ContentHash.sha256Hex(of: drawingData)
        let meta = PageMeta(
            lastModified: Date(),
            deviceID: DeviceIdentity.current,
            contentHash: hash,
            annotations: annotations
        )
        try AtomicFileWriter.writeJSON(meta, to: PackageLayout.pageMetaURL(package: package, pageID: pageID), encoder: ManifestCoding.encoder)
        return hash
    }

    static func insertBlankPage(package: URL, pageID: UUID) throws {
        try writeEmptyPage(package: package, pageID: pageID)
    }

    static func deletePageFiles(package: URL, pageID: UUID) throws {
        let dir = PackageLayout.pageDirectory(package: package, pageID: pageID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
