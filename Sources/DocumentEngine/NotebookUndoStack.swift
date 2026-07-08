import Foundation

/// One per notebook (§5). Handles page insert/delete/reorder, document import/removal,
/// and template/paper changes — deliberately a separate scope from `PageUndoStack`
/// because a page reorder landing in a page's ink undo history would be incoherent.
@MainActor
final class NotebookUndoStack {
    static let memoryBudgetBytes = 20 * 1024 * 1024

    let notebookID: UUID
    private let undoManager = UndoManager()
    private var commands: [UndoCommand] = []
    private var commandsBytes = 0

    init(notebookID: UUID) {
        self.notebookID = notebookID
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    func perform(_ command: UndoCommand) {
        command.redo()
        commands.append(command)
        commandsBytes += command.estimatedByteCost
        registerUndo(for: command, isRedo: false)
        evictOldestIfOverBudget()
    }

    private func registerUndo(for command: UndoCommand, isRedo: Bool) {
        undoManager.registerUndo(withTarget: self) { stack in
            if isRedo {
                command.redo()
            } else {
                command.undo()
            }
            stack.registerUndo(for: command, isRedo: !isRedo)
        }
    }

    private func evictOldestIfOverBudget() {
        while commandsBytes > Self.memoryBudgetBytes, !commands.isEmpty {
            let oldest = commands.removeFirst()
            commandsBytes -= oldest.estimatedByteCost
        }
    }
}
