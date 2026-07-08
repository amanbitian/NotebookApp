// Generic command-based undo/redo, memory-capped rather than count-capped (§5: "one op
// may be a two-point stroke or a 5,000-stroke paste"). Two independent instances are
// created — one per open page (ink/annotation edits) and one per notebook (page
// insert/delete/reorder) — because a page reorder landing in a page's ink undo history
// would be incoherent, same rationale as the Swift app's PageUndoStack/NotebookUndoStack.
export class UndoStack {
  constructor({ budgetBytes }) {
    this.budgetBytes = budgetBytes;
    this.undoList = []; // [{ command, cost }]
    this.redoList = [];
    this.usedBytes = 0;
  }

  // `await`-ing a plain (non-Promise) return value is a no-op, so this stays a drop-in
  // replacement for the many synchronous commands (stroke add/erase, annotation
  // edits) while letting commands that do real IndexedDB writes (page insert/delete)
  // be awaited by the caller instead of firing and forgetting.
  async perform(command) {
    await command.redo();
    this.redoList = [];
    this.undoList.push({ command, cost: command.estimatedByteCost || 0 });
    this.usedBytes += command.estimatedByteCost || 0;
    this._evictIfNeeded();
  }

  async undo() {
    const entry = this.undoList.pop();
    if (!entry) return;
    await entry.command.undo();
    this.redoList.push(entry);
    this.usedBytes -= entry.cost;
  }

  async redo() {
    const entry = this.redoList.pop();
    if (!entry) return;
    await entry.command.redo();
    this.undoList.push(entry);
    this.usedBytes += entry.cost;
  }

  get canUndo() {
    return this.undoList.length > 0;
  }

  get canRedo() {
    return this.redoList.length > 0;
  }

  _evictIfNeeded() {
    while (this.usedBytes > this.budgetBytes && this.undoList.length > 0) {
      const oldest = this.undoList.shift();
      this.usedBytes -= oldest.cost;
    }
  }
}

export const PAGE_UNDO_BUDGET_BYTES = 10 * 1024 * 1024;
export const NOTEBOOK_UNDO_BUDGET_BYTES = 20 * 1024 * 1024;
