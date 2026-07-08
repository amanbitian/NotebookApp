import Foundation

/// One per open page (§5). Ink stroke undo/redo is handled entirely by PencilKit's own
/// `UndoManager` integration — "it already does stroke-level undo correctly," so this
/// type does not reimplement stroke diffing. It does two things:
///
/// 1. Bounds the *ink* undo history via `UndoManager.levelsOfUndo`, which — like the
///    app's own command stack — discards the oldest undo group once exceeded.
/// 2. Registers non-ink commands (annotation edits) onto that same `UndoManager` so a
///    single Cmd-Z timeline interleaves ink and annotation edits in the order they
///    happened, giving "one consistent undo UX" as required by §5.
///
/// Released with the page under memory pressure, per §5's rationale for two scopes.
@MainActor
final class PageUndoStack {
    static let memoryBudgetBytes = 10 * 1024 * 1024

    let pageID: UUID

    private weak var canvasUndoManager: UndoManager?
    private var appCommands: [UndoCommand] = []
    private var appCommandsBytes = 0
    private var recentInkOpByteSizes: [Int] = []

    init(pageID: UUID) {
        self.pageID = pageID
    }

    /// Call once the page's `PKCanvasView` is on-screen and its `UndoManager` (from the
    /// responder chain) is available.
    func attach(canvasUndoManager: UndoManager) {
        self.canvasUndoManager = canvasUndoManager
        rebalanceInkLevels()
    }

    var canUndo: Bool { canvasUndoManager?.canUndo ?? false }
    var canRedo: Bool { canvasUndoManager?.canRedo ?? false }
    func undo() { canvasUndoManager?.undo() }
    func redo() { canvasUndoManager?.redo() }

    /// Called from `canvasViewDrawingDidChange` bookkeeping (not per-callback — once
    /// per settled stroke) so the ink budget can be re-balanced against recent op sizes.
    func noteInkActivity(approximateByteSize: Int) {
        recentInkOpByteSizes.append(approximateByteSize)
        if recentInkOpByteSizes.count > 200 {
            recentInkOpByteSizes.removeFirst()
        }
        rebalanceInkLevels()
    }

    private func rebalanceInkLevels() {
        guard let manager = canvasUndoManager else { return }
        let averageOpSize = recentInkOpByteSizes.isEmpty
            ? 2_000
            : recentInkOpByteSizes.reduce(0, +) / recentInkOpByteSizes.count
        let inkBudget = max(Self.memoryBudgetBytes - appCommandsBytes, Self.memoryBudgetBytes / 4)
        manager.levelsOfUndo = max(10, min(500, inkBudget / max(averageOpSize, 1)))
    }

    /// Applies and registers a non-ink command (annotation move/resize/edit, text
    /// content edit) onto the shared undo timeline.
    func perform(_ command: UndoCommand) {
        command.redo()
        appCommands.append(command)
        appCommandsBytes += command.estimatedByteCost
        registerUndo(for: command, isRedo: false)
        evictOldestIfOverBudget()
        rebalanceInkLevels()
    }

    private func registerUndo(for command: UndoCommand, isRedo: Bool) {
        canvasUndoManager?.registerUndo(withTarget: self) { stack in
            if isRedo {
                command.redo()
            } else {
                command.undo()
            }
            stack.registerUndo(for: command, isRedo: !isRedo)
        }
    }

    private func evictOldestIfOverBudget() {
        while appCommandsBytes > Self.memoryBudgetBytes, !appCommands.isEmpty {
            let oldest = appCommands.removeFirst()
            appCommandsBytes -= oldest.estimatedByteCost
        }
    }
}
