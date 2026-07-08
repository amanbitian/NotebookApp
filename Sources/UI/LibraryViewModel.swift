import Foundation
import SwiftUI

struct NotebookSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let packageURL: URL
}

/// Library-level state: what notebooks exist and which one (if any) is currently
/// open. Backed by a directory scan of `.notepkg` packages — the library list itself
/// is derived, not a source of truth (P2); nothing here is more authoritative than
/// the packages on disk.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var notebooks: [NotebookSummary] = []
    @Published private(set) var openCoordinator: NotebookCoordinator?

    private let indexStore: IndexStore?
    let rootDirectory: URL

    init() {
        rootDirectory = Self.resolveRootDirectory()
        indexStore = try? IndexStore()
        rescan()
    }

    /// Prefers the iCloud ubiquity container (§6.3) so newly imported notebooks land
    /// in the synced zone by default; falls back to local Documents if iCloud isn't
    /// available (P1 — local editing must never depend on network/account state).
    private static func resolveRootDirectory() -> URL {
        if let container = ICloudSyncAdapter.ubiquityContainerURL() {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }
        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return documents
    }

    func rescan() {
        let items = (try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        notebooks = items
            .filter { $0.pathExtension == "notepkg" }
            .compactMap { url in
                guard let recovered = try? NotebookPackage.loadManifest(package: url) else { return nil }
                return NotebookSummary(id: recovered.manifest.notebookID, title: recovered.manifest.title, packageURL: url)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func importPDF(at sourceURL: URL, title: String) -> ImportJob {
        let job = ImportJob()
        job.importPDF(at: sourceURL, title: title, into: rootDirectory)
        return job
    }

    func open(_ summary: NotebookSummary) {
        guard let indexStore else { return }
        guard let recovered = try? NotebookPackage.loadManifest(package: summary.packageURL) else { return }
        let notebook = Notebook(manifest: recovered.manifest, packageURL: summary.packageURL)
        openCoordinator = try? NotebookCoordinator(notebook: notebook, indexStore: indexStore)
    }

    func close() {
        openCoordinator = nil
    }
}
