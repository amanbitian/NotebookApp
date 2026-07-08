import Foundation
import PencilKit

/// Runtime, in-memory representation of one page. Backed on disk by
/// `pages/<id>/drawing.data` + `pages/<id>/meta.json`.
///
/// `PKDrawing` is a value type (§5 note 2): it is safe to snapshot `drawing` off the
/// main thread for background serialization without locking the canvas.
@MainActor
final class Page: ObservableObject {
    let id: UUID

    @Published var drawing: PKDrawing {
        didSet { revision += 1 }
    }
    @Published var meta: PageMeta
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var conflict: PageConflict?

    /// Bumped on every `drawing` assignment, regardless of origin (local ink, sync
    /// download, merge, conflict resolution). `CanvasView` uses this to tell "the
    /// canvas already reflects this" apart from "an external write needs pushing into
    /// the canvas," without re-serializing or deep-comparing `PKDrawing` on every
    /// SwiftUI body re-evaluation.
    private(set) var revision: Int = 0

    private(set) var undoStack: PageUndoStack

    init(id: UUID, drawing: PKDrawing, meta: PageMeta) {
        self.id = id
        self.drawing = drawing
        self.meta = meta
        self.undoStack = PageUndoStack(pageID: id)
    }

    /// Marks the page dirty in memory only — no I/O. Called from
    /// `canvasViewDrawingDidChange`, which can fire many times per second (§5 note 1).
    func markDirty() {
        isDirty = true
    }

    func clearDirty() {
        isDirty = false
    }

    func setConflict(_ conflict: PageConflict?) {
        self.conflict = conflict
    }
}

/// Surfaced on a page when §7 conflict detection fires and resolution falls back to
/// both-versions-kept. Resolving is always a user action, never a timeout (§7.3).
struct PageConflict: Equatable {
    enum Resolution {
        case keepMine
        case keepTheirs
        case keepBoth
    }

    let pageID: UUID
    let localSnapshotHash: String
    let remoteSnapshotHash: String
    let detectedAt: Date
}
