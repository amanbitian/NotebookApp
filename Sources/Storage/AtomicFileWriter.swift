import Foundation

/// Every write to a synced file in this app goes through here. Temp file in the same
/// directory, then `replaceItemAt`, so a crash mid-write leaves the previous version
/// intact rather than a half-written file (§5 note 3, §4 rule 2).
enum AtomicFileWriter {

    enum WriteError: Error {
        case couldNotCreateParentDirectory(URL, underlying: Error)
    }

    /// Writes `data` to `url` atomically. The temp file is created alongside the
    /// destination (same volume) so the final replace is a metadata-only rename, not a
    /// cross-volume copy.
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw WriteError.couldNotCreateParentDirectory(directory, underlying: error)
            }
        }

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    /// Convenience for JSON-encodable values (manifest, meta.json).
    static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(value)
        try write(data, to: url)
    }
}
