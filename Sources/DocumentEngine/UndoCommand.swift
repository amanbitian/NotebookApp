import Foundation

/// A single undoable operation. `estimatedByteCost` drives the memory-based eviction
/// described in §5 — the cap is memory, not op count, because "one op may be a
/// two-point stroke or a 5,000-stroke paste."
protocol UndoCommand {
    var estimatedByteCost: Int { get }
    func undo()
    func redo()
}

/// Annotation move/resize/edit and text-box content edits (page-scoped, §5).
struct AnnotationEditCommand: UndoCommand {
    let before: Annotation
    let after: Annotation
    let apply: (Annotation) -> Void

    var estimatedByteCost: Int {
        after.content.utf8.count + 64
    }

    func undo() { apply(before) }
    func redo() { apply(after) }
}

/// Page insert/delete/reorder, document import/removal, template changes
/// (notebook-scoped, §5).
struct NotebookStructureCommand: UndoCommand {
    let estimatedByteCost: Int
    let performUndo: () -> Void
    let performRedo: () -> Void

    func undo() { performUndo() }
    func redo() { performRedo() }
}
