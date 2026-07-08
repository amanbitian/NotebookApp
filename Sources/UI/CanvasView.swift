import PencilKit
import SwiftUI

/// Thin `UIViewRepresentable` wrapper around `PKCanvasView`. The render path
/// (PencilKit) and the persistence path are fully decoupled (P1) — this view only
/// forwards the change notification to `NotebookCoordinator`; it never touches disk.
struct CanvasView: UIViewRepresentable {
    @ObservedObject var page: Page
    let coordinator: NotebookCoordinator
    var tool: PKTool = PKInkingTool(.pen, color: .black, width: 4)

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.drawing = page.drawing
        canvasView.tool = tool
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        context.coordinator.lastAppliedRevision = page.revision

        // Ink undo/redo lives entirely in this UndoManager; PageUndoStack only bounds
        // and interleaves it (§5).
        if let undoManager = canvasView.undoManager {
            page.undoStack.attach(canvasUndoManager: undoManager)
        }
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        // Only push `page.drawing` into the canvas when it changed for a reason other
        // than the canvas's own delegate callback (e.g. an incoming sync/merge/conflict
        // resolution) — see `Page.revision`.
        if page.revision != context.coordinator.lastAppliedRevision {
            canvasView.drawing = page.drawing
            context.coordinator.lastAppliedRevision = page.revision
        }
        canvasView.tool = tool
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, notebookCoordinator: coordinator)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let page: Page
        private let notebookCoordinator: NotebookCoordinator
        var lastAppliedRevision = -1
        private var lastStrokeCount: Int

        init(page: Page, notebookCoordinator: NotebookCoordinator) {
            self.page = page
            self.notebookCoordinator = notebookCoordinator
            self.lastStrokeCount = page.drawing.strokes.count
        }

        /// Fires frequently — cheap handler only (§5 note 1). No serialization, no
        /// disk I/O here; that all happens later on a background queue via the
        /// autosave pipeline's debounce.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let newStrokeCount = canvasView.drawing.strokes.count
            let strokeDelta = abs(newStrokeCount - lastStrokeCount)
            lastStrokeCount = newStrokeCount

            page.drawing = canvasView.drawing
            lastAppliedRevision = page.revision
            notebookCoordinator.handleDrawingChanged(page: page)

            if strokeDelta > 0 {
                // Coarse proxy for ink memory cost — avoids serializing the drawing
                // just to measure it inside this hot callback.
                page.undoStack.noteInkActivity(approximateByteSize: strokeDelta * 200)
            }
        }

        /// Mitigates the "final debounce window at risk" failure mode (§10).
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            notebookCoordinator.handlePencilLift(page: page)
        }
    }
}
