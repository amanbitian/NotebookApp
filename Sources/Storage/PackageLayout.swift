import Foundation

/// Path conventions for the synced `.notepkg` zone (§3.1) and the local-only derived
/// zone (§3.2). Centralized here so no other file hand-rolls a path string.
enum PackageLayout {

    // MARK: Synced zone — inside `<name>.notepkg/`

    static func manifestURL(package: URL) -> URL {
        package.appendingPathComponent("manifest.json")
    }

    static func sourcePDFURL(package: URL) -> URL {
        package.appendingPathComponent("source.pdf")
    }

    static func pagesDirectory(package: URL) -> URL {
        package.appendingPathComponent("pages")
    }

    static func pageDirectory(package: URL, pageID: UUID) -> URL {
        pagesDirectory(package: package).appendingPathComponent(pageID.uuidString)
    }

    static func drawingDataURL(package: URL, pageID: UUID) -> URL {
        pageDirectory(package: package, pageID: pageID).appendingPathComponent("drawing.data")
    }

    static func pageMetaURL(package: URL, pageID: UUID) -> URL {
        pageDirectory(package: package, pageID: pageID).appendingPathComponent("meta.json")
    }

    /// Inserted-image annotations are user content, not derived data — unlike
    /// thumbnails, they must reach other devices, so they live inside the synced page
    /// folder rather than a local cache. Written once per image and never modified in
    /// place, same immutability rationale as `source.pdf` (§3.1).
    static func pageImagesDirectory(package: URL, pageID: UUID) -> URL {
        pageDirectory(package: package, pageID: pageID).appendingPathComponent("images", isDirectory: true)
    }

    static func pageImageURL(package: URL, pageID: UUID, fileName: String) -> URL {
        pageImagesDirectory(package: package, pageID: pageID).appendingPathComponent(fileName)
    }

    // MARK: Local-only zone — `Application Support/notebooks/<notebookUUID>/`

    static func localStoreRoot(notebookID: UUID) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("notebooks", isDirectory: true)
            .appendingPathComponent(notebookID.uuidString, isDirectory: true)
    }

    static func journalDatabaseURL(notebookID: UUID) throws -> URL {
        try localStoreRoot(notebookID: notebookID).appendingPathComponent("journal.sqlite")
    }

    static func indexDatabaseURL(notebookID: UUID) throws -> URL {
        try localStoreRoot(notebookID: notebookID).appendingPathComponent("index.sqlite")
    }

    static func mergeBaseDirectory(notebookID: UUID) throws -> URL {
        try localStoreRoot(notebookID: notebookID).appendingPathComponent("merge-base", isDirectory: true)
    }

    static func mergeBaseURL(notebookID: UUID, pageID: UUID) throws -> URL {
        try mergeBaseDirectory(notebookID: notebookID).appendingPathComponent("\(pageID.uuidString).data")
    }

    // MARK: Caches — fully disposable, may be purged by the OS at any time

    static func thumbnailsDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appendingPathComponent("thumbs", isDirectory: true)
    }

    static func thumbnailURL(pageID: UUID, contentHash: String) throws -> URL {
        try thumbnailsDirectory().appendingPathComponent("\(pageID.uuidString)-\(contentHash).jpg")
    }
}
