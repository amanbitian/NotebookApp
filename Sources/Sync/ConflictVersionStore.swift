import Foundation
import PencilKit

/// Where the "losing" version goes in both-versions-kept fallback mode (§7.3): "both
/// versions are kept, the newer becomes the active page, the other is stored as a
/// recoverable version." Local-only — this is recovery scratch space, not synced
/// content in its own right (until the user resolves it, at which point it either
/// becomes a real page, via `pages/<uuid>/`, or is discarded).
enum ConflictVersionStore {

    private static func directory(notebookID: UUID) throws -> URL {
        try PackageLayout.localStoreRoot(notebookID: notebookID).appendingPathComponent("conflict-versions", isDirectory: true)
    }

    private static func url(notebookID: UUID, pageID: UUID, hash: String) throws -> URL {
        try directory(notebookID: notebookID).appendingPathComponent("\(pageID.uuidString)-\(hash).data")
    }

    static func store(notebookID: UUID, pageID: UUID, hash: String, drawing: PKDrawing) throws {
        try AtomicFileWriter.write(drawing.dataRepresentation(), to: url(notebookID: notebookID, pageID: pageID, hash: hash))
    }

    static func load(notebookID: UUID, pageID: UUID, hash: String) -> PKDrawing? {
        guard let fileURL = try? url(notebookID: notebookID, pageID: pageID, hash: hash),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? PKDrawing(data: data)
    }

    static func discard(notebookID: UUID, pageID: UUID, hash: String) throws {
        guard let fileURL = try? url(notebookID: notebookID, pageID: pageID, hash: hash) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
