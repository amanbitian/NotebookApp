import PhotosUI
import SwiftUI
import UIKit

/// Renders a page's non-ink annotations (images, text boxes) on top of the ink
/// canvas, and lets the user move or delete them. Annotation moves are page-scoped
/// undo operations per §5's undo table ("annotation move/resize/edit").
struct AnnotationOverlayView: View {
    @ObservedObject var page: Page
    let coordinator: NotebookCoordinator

    var body: some View {
        ForEach(page.meta.annotations) { annotation in
            AnnotationItemView(page: page, coordinator: coordinator, annotation: annotation)
        }
    }
}

private struct AnnotationItemView: View {
    @ObservedObject var page: Page
    let coordinator: NotebookCoordinator
    let annotation: Annotation

    @State private var dragTranslation: CGSize = .zero
    @State private var image: UIImage?
    @State private var showingImageEditor = false
    @State private var replacementPhotoItem: PhotosPickerItem?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: annotation.frame.width, height: annotation.frame.height)

            HStack(spacing: 6) {
                if annotation.kind == .image {
                    Button {
                        showingImageEditor = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.white, .blue.opacity(0.75))
                    }

                    PhotosPicker(selection: $replacementPhotoItem, matching: .images) {
                        Image(systemName: "photo.circle.fill")
                            .foregroundStyle(.white, .green.opacity(0.75))
                    }
                }

                Button(action: deleteAnnotation) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
            }
            .offset(x: 10, y: -10)
        }
        .position(
            x: annotation.frame.midX + dragTranslation.width,
            y: annotation.frame.midY + dragTranslation.height
        )
        .gesture(
            DragGesture()
                .onChanged { value in dragTranslation = value.translation }
                .onEnded { value in commitMove(translation: value.translation) }
        )
        .onAppear(perform: loadImageIfNeeded)
        .onChange(of: replacementPhotoItem) { _, newItem in
            replaceImage(from: newItem)
        }
        .sheet(isPresented: $showingImageEditor) {
            ImageAnnotationEditorSheet(annotation: annotation, imageSize: image?.size) { frame in
                commitFrameEdit(frame)
            }
        }
    }

    private func replaceImage(from item: PhotosPickerItem?) {
        guard let item, annotation.kind == .image else { return }
        Task {
            defer { replacementPhotoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                return
            }

            let jpegData = uiImage.jpegData(compressionQuality: 0.85) ?? data
            guard let content = try? coordinator.saveImage(pageID: page.id, data: jpegData) else { return }

            var edited = annotation
            edited.content = content
            edited.lastModified = Date()
            if uiImage.size.width > 0 {
                edited.frame.size.height = edited.frame.width * (uiImage.size.height / uiImage.size.width)
            }

            image = uiImage
            commitAnnotationEdit(edited)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch annotation.kind {
        case .image:
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.gray.opacity(0.2)
            }
        case .text:
            Text(annotation.content)
                .padding(4)
                .background(Color.yellow.opacity(0.3))
        case .shape:
            Color.clear
        }
    }

    private func loadImageIfNeeded() {
        guard annotation.kind == .image, image == nil else { return }
        if let data = coordinator.loadImage(pageID: page.id, fileName: annotation.content) {
            image = UIImage(data: data)
        }
    }

    private func commitMove(translation: CGSize) {
        guard translation != .zero else { return }
        var moved = annotation
        moved.frame.origin.x += translation.width
        moved.frame.origin.y += translation.height
        moved.lastModified = Date()
        dragTranslation = .zero

        commitAnnotationEdit(moved)
    }

    private func commitFrameEdit(_ frame: CGRect) {
        guard frame != annotation.frame else { return }
        var edited = annotation
        edited.frame = frame
        edited.lastModified = Date()
        commitAnnotationEdit(edited)
    }

    private func commitAnnotationEdit(_ edited: Annotation) {
        page.undoStack.perform(AnnotationEditCommand(before: annotation, after: edited) { updated in
            if let index = page.meta.annotations.firstIndex(where: { $0.id == updated.id }) {
                page.meta.annotations[index] = updated
            }
        })
        coordinator.handleAnnotationsChanged(page: page)
    }

    private func deleteAnnotation() {
        page.undoStack.perform(AnnotationDeleteCommand(page: page, annotation: annotation))
        coordinator.handleAnnotationsChanged(page: page)
    }
}

private struct ImageAnnotationEditorSheet: View {
    let annotation: Annotation
    let imageSize: CGSize?
    let onApply: (CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftX: Double
    @State private var draftY: Double
    @State private var draftWidth: Double
    @State private var draftHeight: Double
    @State private var lockAspectRatio = true

    init(annotation: Annotation, imageSize: CGSize?, onApply: @escaping (CGRect) -> Void) {
        self.annotation = annotation
        self.imageSize = imageSize
        self.onApply = onApply
        _draftX = State(initialValue: Double(annotation.frame.origin.x))
        _draftY = State(initialValue: Double(annotation.frame.origin.y))
        _draftWidth = State(initialValue: Double(annotation.frame.width))
        _draftHeight = State(initialValue: Double(annotation.frame.height))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    Stepper("X: \(Int(draftX))", value: $draftX, in: -2000...2000, step: 5)
                    Stepper("Y: \(Int(draftY))", value: $draftY, in: -2000...2000, step: 5)
                }

                Section("Size") {
                    Toggle("Lock aspect ratio", isOn: $lockAspectRatio)
                    Stepper("Width: \(Int(draftWidth))", value: widthBinding, in: 20...3000, step: 10)
                    Stepper("Height: \(Int(draftHeight))", value: heightBinding, in: 20...3000, step: 10)
                    Button("Reset to image ratio", action: resetToImageRatio)
                        .disabled(imageAspectRatio == nil)
                }
            }
            .navigationTitle("Edit Picture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(CGRect(
                            x: CGFloat(draftX),
                            y: CGFloat(draftY),
                            width: CGFloat(max(draftWidth, 1)),
                            height: CGFloat(max(draftHeight, 1))
                        ))
                        dismiss()
                    }
                }
            }
        }
    }

    private var currentAspectRatio: Double {
        max(draftHeight, 1) / max(draftWidth, 1)
    }

    private var imageAspectRatio: Double? {
        guard let imageSize, imageSize.width > 0 else { return nil }
        return Double(imageSize.height / imageSize.width)
    }

    private var widthBinding: Binding<Double> {
        Binding {
            draftWidth
        } set: { newValue in
            let aspectRatio = imageAspectRatio ?? currentAspectRatio
            draftWidth = newValue
            if lockAspectRatio {
                draftHeight = newValue * aspectRatio
            }
        }
    }

    private var heightBinding: Binding<Double> {
        Binding {
            draftHeight
        } set: { newValue in
            let aspectRatio = imageAspectRatio ?? currentAspectRatio
            draftHeight = newValue
            if lockAspectRatio {
                draftWidth = newValue / max(aspectRatio, 0.001)
            }
        }
    }

    private func resetToImageRatio() {
        guard let imageAspectRatio else { return }
        draftHeight = draftWidth * imageAspectRatio
    }
}
