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

/// Inserting a new annotation (image or text box) onto a page (page-scoped, §5).
/// Idempotent by id on `redo`, matching the ink undo stack's pattern: the initial
/// `perform()` call applies the insert once, and later redo-after-undo cycles must
/// not duplicate it.
struct AnnotationInsertCommand: UndoCommand {
    let page: Page
    let annotation: Annotation

    var estimatedByteCost: Int {
        annotation.content.utf8.count + 256
    }

    func redo() {
        if !page.meta.annotations.contains(where: { $0.id == annotation.id }) {
            page.meta.annotations.append(annotation)
        }
    }

    func undo() {
        page.meta.annotations.removeAll { $0.id == annotation.id }
    }
}

/// Deleting an existing annotation from a page (page-scoped, §5). The image file
/// backing an `.image` annotation, if any, is left on disk until the command is
/// evicted from the undo stack or the page is otherwise known to be done with it —
/// deleting it eagerly here would break undo.
struct AnnotationDeleteCommand: UndoCommand {
    let page: Page
    let annotation: Annotation

    var estimatedByteCost: Int {
        annotation.content.utf8.count + 256
    }

    func redo() {
        page.meta.annotations.removeAll { $0.id == annotation.id }
    }

    func undo() {
        if !page.meta.annotations.contains(where: { $0.id == annotation.id }) {
            page.meta.annotations.append(annotation)
        }
    }
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
