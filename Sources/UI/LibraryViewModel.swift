import Foundation
import SwiftUI
import UIKit

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
    @Published private(set) var openCoordinators: [NotebookCoordinator] = []
    @Published var activeNotebookID: UUID?

    private let indexStore: IndexStore?
    let rootDirectory: URL

    var activeCoordinator: NotebookCoordinator? {
        guard let activeNotebookID else { return openCoordinators.first }
        return openCoordinators.first { $0.notebook.id == activeNotebookID }
    }

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
        if let importURL = try? Self.copyToTemporaryImportURL(sourceURL) {
            job.importPDF(at: importURL, title: title, into: rootDirectory, cleanupSourceWhenFinished: true)
        } else {
            job.importPDF(at: sourceURL, title: title, into: rootDirectory)
        }
        return job
    }

    @discardableResult
    func importImage(at sourceURL: URL, title: String) -> ImportJob? {
        let job = ImportJob()
        guard let image = UIImage(contentsOfFile: sourceURL.path) else {
            return nil
        }
        job.importImages([image], title: title, into: rootDirectory)
        return job
    }

    private static func copyToTemporaryImportURL(_ sourceURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func open(_ summary: NotebookSummary) {
        if openCoordinators.contains(where: { $0.notebook.id == summary.id }) {
            activeNotebookID = summary.id
            return
        }

        guard let indexStore else { return }
        guard let recovered = try? NotebookPackage.loadManifest(package: summary.packageURL) else { return }
        let notebook = Notebook(manifest: recovered.manifest, packageURL: summary.packageURL)
        guard let coordinator = try? NotebookCoordinator(notebook: notebook, indexStore: indexStore) else { return }
        openCoordinators.append(coordinator)
        activeNotebookID = coordinator.notebook.id
    }

    func activate(_ coordinator: NotebookCoordinator) {
        activeNotebookID = coordinator.notebook.id
    }

    /// Awaits the flush *before* dropping the coordinator — closing a tab is another
    /// moment a page can be mid-debounce, same as page exit / app backgrounding
    /// (§5 note 4). Firing the flush without awaiting it left a real window where
    /// backgrounding or terminating right after a close could drop the final
    /// autosave, since the coordinator was already gone from `openCoordinators` by
    /// the time `flushAllOpenImmediately()` ran on backgrounding.
    func close(_ coordinator: NotebookCoordinator) async {
        await coordinator.flushAllImmediately()
        openCoordinators.removeAll { $0.notebook.id == coordinator.notebook.id }
        if activeNotebookID == coordinator.notebook.id {
            activeNotebookID = openCoordinators.last?.notebook.id
        }
    }

    func closeActive() async {
        guard let activeCoordinator else { return }
        await close(activeCoordinator)
    }

    func closeAll() async {
        for coordinator in openCoordinators {
            await coordinator.flushAllImmediately()
        }
        openCoordinators.removeAll()
        activeNotebookID = nil
    }

    func flushAllOpenImmediately() async {
        for coordinator in openCoordinators {
            await coordinator.flushAllImmediately()
        }
    }
}
