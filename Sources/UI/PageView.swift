import PhotosUI
import SwiftUI

struct PageView: View {
    @ObservedObject var notebook: Notebook
    let pageID: UUID
    let coordinator: NotebookCoordinator

    @State private var page: Page?
    @State private var loadError: String?
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        Group {
            if let page {
                ZStack(alignment: .topTrailing) {
                    CanvasView(page: page, coordinator: coordinator)
                    AnnotationOverlayView(page: page, coordinator: coordinator)
                    if let conflict = page.conflict {
                        ConflictBadgeView(notebook: notebook, pageID: pageID, conflict: conflict, coordinator: coordinator)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title2)
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                    }
                    .padding()
                }
            } else if let loadError {
                Text("Couldn't load page: \(loadError)")
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: loadPage)
        .onChange(of: selectedPhotoItem) { _, newItem in
            insertImage(from: newItem)
        }
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

    /// Inserts a picked photo as a new image annotation (§5 undo scope table:
    /// annotation inserts are page-scoped, undoable ops).
    private func insertImage(from item: PhotosPickerItem?) {
        guard let item, let page else { return }
        Task {
            defer { selectedPhotoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                return
            }

            let jpegData = uiImage.jpegData(compressionQuality: 0.85) ?? data
            guard let fileName = try? coordinator.saveImage(pageID: page.id, data: jpegData) else { return }

            let defaultWidth: CGFloat = 200
            let aspectRatio = uiImage.size.height / max(uiImage.size.width, 1)
            let frame = CGRect(x: 40, y: 40, width: defaultWidth, height: defaultWidth * aspectRatio)
            let annotation = Annotation(kind: .image, frame: frame, content: fileName)

            page.undoStack.perform(AnnotationInsertCommand(page: page, annotation: annotation))
            coordinator.handleAnnotationsChanged(page: page)
        }
    }
}
