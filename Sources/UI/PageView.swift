import SwiftUI

struct PageView: View {
    @ObservedObject var notebook: Notebook
    let pageID: UUID
    let coordinator: NotebookCoordinator

    @State private var page: Page?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let page {
                ZStack(alignment: .topTrailing) {
                    CanvasView(page: page, coordinator: coordinator)
                    if let conflict = page.conflict {
                        ConflictBadgeView(notebook: notebook, pageID: pageID, conflict: conflict, coordinator: coordinator)
                    }
                }
            } else if let loadError {
                Text("Couldn't load page: \(loadError)")
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: loadPage)
        .onDisappear {
            // Page exit bypasses the debounce (§5 note 4) — one of the two moments
            // users lose data in badly built apps.
            Task { await coordinator.flushAllImmediately() }
        }
    }

    private func loadPage() {
        guard page == nil else { return }
        do {
            page = try coordinator.openPage(pageID)
        } catch {
            loadError = String(describing: error)
        }
    }
}
