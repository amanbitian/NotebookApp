import Foundation

/// Runtime aggregate for an open notebook: the manifest plus whichever pages are
/// currently loaded. Per the non-functional target in §11 ("Open = manifest + visible
/// pages only"), pages are loaded lazily via `NotebookPackage`, not all at once.
@MainActor
final class Notebook: ObservableObject {
    @Published private(set) var manifest: Manifest {
        didSet { rebuildPageIndex() }
    }
    @Published private(set) var loadedPages: [UUID: Page] = [:]

    let packageURL: URL
    private(set) var undoStack: NotebookUndoStack
    private var pageIndexByID: [UUID: Int] = [:]

    var id: UUID { manifest.notebookID }

    /// Page order is authoritative from the manifest, never inferred from page files
    /// (§3.1: "Pages are identified by UUID, never by position").
    var pageOrder: [UUID] {
        manifest.pageOrder
    }

    init(manifest: Manifest, packageURL: URL) {
        self.manifest = manifest
        self.packageURL = packageURL
        self.undoStack = NotebookUndoStack(notebookID: manifest.notebookID)
        rebuildPageIndex()
    }

    func page(for id: UUID) -> Page? {
        loadedPages[id]
    }

    func pageIndex(for id: UUID) -> Int? {
        pageIndexByID[id]
    }

    func registerLoaded(_ page: Page) {
        loadedPages[page.id] = page
    }

    /// Releases an in-memory page (e.g. under memory pressure or when it scrolls far
    /// off-screen). Safe because the page-scoped undo stack lives with the page and is
    /// released alongside it (§5, "Two scopes... page-scoped stacks can be released
    /// with the page under memory pressure").
    func unloadPage(_ id: UUID) {
        loadedPages.removeValue(forKey: id)
    }

    // MARK: - Structural mutations (notebook-undo scope)

    func insertPage(_ pageID: UUID, at index: Int) {
        var manifest = self.manifest
        manifest.pageOrder.insert(pageID, at: min(index, manifest.pageOrder.count))
        manifest.updatedAt = Date()
        self.manifest = manifest
    }

    func removePage(_ pageID: UUID) {
        var manifest = self.manifest
        manifest.pageOrder.removeAll { $0 == pageID }
        manifest.updatedAt = Date()
        self.manifest = manifest
        loadedPages.removeValue(forKey: pageID)
    }

    func movePage(from source: Int, to destination: Int) {
        var manifest = self.manifest
        guard manifest.pageOrder.indices.contains(source) else { return }
        let id = manifest.pageOrder.remove(at: source)
        manifest.pageOrder.insert(id, at: min(destination, manifest.pageOrder.count))
        manifest.updatedAt = Date()
        self.manifest = manifest
    }

    func replaceManifest(_ newManifest: Manifest) {
        self.manifest = newManifest
    }

    private func rebuildPageIndex() {
        pageIndexByID = Dictionary(uniqueKeysWithValues: manifest.pageOrder.enumerated().map { ($0.element, $0.offset) })
    }
}
