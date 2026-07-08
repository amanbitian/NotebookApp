import Foundation
import ZIPFoundation

enum PackageSnapshotError: Error {
    case packageMissing
}

enum PackageSnapshotBuilder {
    static func makeZippedSnapshot(packageURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw PackageSnapshotError.packageMissing
        }

        let baseName = packageURL.deletingPathExtension().lastPathComponent
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
            .appendingPathExtension("notepkg.zip")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        try FileManager.default.zipItem(at: packageURL, to: outputURL, shouldKeepParent: true)
        return outputURL
    }
}
