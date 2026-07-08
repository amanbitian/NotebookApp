import { Notebooks, Pages } from "./db.js";
import { createPage, createImageAnnotation, createTextAnnotation } from "./models.js";
import { CanvasView } from "./canvasView.js";
import { UndoStack, PAGE_UNDO_BUDGET_BYTES, NOTEBOOK_UNDO_BUDGET_BYTES } from "./undoStack.js";
import { AutosavePipeline } from "./autosave.js";
import { importPdfFile, createBlankNotebook, renderPdfPageToCanvas, US_LETTER_CSS } from "./pdfImport.js";
import { exportNotebookToPdf } from "./pdfExport.js";
import { searchAll } from "./search.js";

// ---- DOM references ----------------------------------------------------
const backButton = document.getElementById("backButton");
const titleLabel = document.getElementById("titleLabel");
const libraryView = document.getElementById("libraryView");
const notebookView = document.getElementById("notebookView");
const notebookList = document.getElementById("notebookList");
const newNotebookButton = document.getElementById("newNotebookButton");
const importPdfInput = document.getElementById("importPdfInput");
const searchInput = document.getElementById("searchInput");
const searchResults = document.getElementById("searchResults");
const pageList = document.getElementById("pageList");
const addPageButton = document.getElementById("addPageButton");
const pageCanvas = document.getElementById("pageCanvas");
const penTool = document.getElementById("penTool");
const eraserTool = document.getElementById("eraserTool");
const textTool = document.getElementById("textTool");
const moveTool = document.getElementById("moveTool");
const imageInput = document.getElementById("imageInput");
const colorPicker = document.getElementById("colorPicker");
const widthPicker = document.getElementById("widthPicker");
const undoButton = document.getElementById("undoButton");
const redoButton = document.getElementById("redoButton");
const conflictBadge = document.getElementById("conflictBadge");
const exportButton = document.getElementById("exportButton");
const deletePageButton = document.getElementById("deletePageButton");

// ---- App-level state -----------------------------------------------------
let currentNotebook = null;
let currentPage = null;
let notebookUndoStack = null;
let pageUndoStack = null;

const autosave = new AutosavePipeline({
  debounceMs: 800,
  onFlushed: () => {
    conflictBadge.hidden = true;
  },
});

const canvasView = new CanvasView(pageCanvas, {
  onStrokeCompleted: async (stroke) => {
    await pageUndoStack.perform({
      estimatedByteCost: JSON.stringify(stroke).length,
      redo: () => canvasView.addStrokeInternal(stroke),
      undo: () => canvasView.removeStrokesInternal([stroke.id]),
    });
    commitPageContentChange();
  },
  onStrokesErased: async (removed) => {
    if (removed.length === 0) return;
    await pageUndoStack.perform({
      estimatedByteCost: JSON.stringify(removed).length,
      redo: () => canvasView.removeStrokesInternal(removed.map((s) => s.id)),
      undo: () => removed.forEach((s) => canvasView.addStrokeInternal(s)),
    });
    commitPageContentChange();
  },
  onTextAnnotationRequested: async (point) => {
    const text = window.prompt("Text annotation:");
    if (!text) return;
    const annotation = createTextAnnotation({ x: point.x, y: point.y, text });
    await pageUndoStack.perform({
      estimatedByteCost: text.length + 32,
      redo: () => canvasView.addAnnotationInternal(annotation),
      undo: () => canvasView.removeAnnotationInternal(annotation.id),
    });
    commitPageContentChange();
  },
  onAnnotationsErased: async (removed) => {
    if (removed.length === 0) return;
    await pageUndoStack.perform({
      estimatedByteCost: removed.reduce((sum, a) => sum + (a.imageBlob?.size || (a.text || "").length + 32), 0),
      redo: () => removed.forEach((a) => canvasView.removeAnnotationInternal(a.id)),
      undo: () => removed.forEach((a) => canvasView.addAnnotationInternal(a)),
    });
    commitPageContentChange();
  },
  onAnnotationMoved: async ({ annotation, fromX, fromY, toX, toY }) => {
    await pageUndoStack.perform({
      estimatedByteCost: 64,
      redo: () => canvasView.moveAnnotationInternal(annotation.id, toX, toY),
      undo: () => canvasView.moveAnnotationInternal(annotation.id, fromX, fromY),
    });
    commitPageContentChange();
  },
  onAnnotationResized: async ({ annotation, fromWidth, fromHeight, toWidth, toHeight }) => {
    await pageUndoStack.perform({
      estimatedByteCost: 64,
      redo: () => canvasView.resizeAnnotationInternal(annotation.id, toWidth, toHeight),
      undo: () => canvasView.resizeAnnotationInternal(annotation.id, fromWidth, fromHeight),
    });
    commitPageContentChange();
  },
});

function commitPageContentChange() {
  if (!currentPage) return;
  currentPage.strokes = canvasView.strokes;
  currentPage.annotations = canvasView.annotations;
  autosave.markDirty(currentPage);
  refreshUndoButtons();
}

function refreshUndoButtons() {
  undoButton.disabled = !pageUndoStack || !pageUndoStack.canUndo;
  redoButton.disabled = !pageUndoStack || !pageUndoStack.canRedo;
}

// ---- Library view --------------------------------------------------------
async function renderLibrary() {
  const notebooks = await Notebooks.getAll();
  notebookList.innerHTML = "";
  notebooks
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .forEach((notebook) => {
      const li = document.createElement("li");
      li.textContent = notebook.title;

      const deleteBtn = document.createElement("button");
      deleteBtn.textContent = "Delete";
      deleteBtn.addEventListener("click", async (event) => {
        event.stopPropagation();
        if (!confirm(`Delete "${notebook.title}"?`)) return;
        await Pages.deleteAllForNotebook(notebook.id);
        await Notebooks.delete(notebook.id);
        renderLibrary();
      });

      li.addEventListener("click", () => openNotebook(notebook.id));
      li.appendChild(deleteBtn);
      notebookList.appendChild(li);
    });
}

newNotebookButton.addEventListener("click", async () => {
  const title = window.prompt("Notebook title:", "New notebook");
  if (!title) return;
  const { notebook, page } = createBlankNotebook(title);
  await Notebooks.put(notebook);
  await Pages.put(page);
  await renderLibrary();
  openNotebook(notebook.id);
});

importPdfInput.addEventListener("change", async (event) => {
  const file = event.target.files[0];
  event.target.value = "";
  if (!file) return;
  const notebook = await importPdfFile(file);
  await renderLibrary();
  openNotebook(notebook.id);
});

let searchDebounce = null;
searchInput.addEventListener("input", () => {
  clearTimeout(searchDebounce);
  searchDebounce = setTimeout(runSearch, 250);
});

async function runSearch() {
  const query = searchInput.value;
  if (!query.trim()) {
    searchResults.hidden = true;
    searchResults.innerHTML = "";
    return;
  }
  const results = await searchAll(query);
  searchResults.innerHTML = "";
  searchResults.hidden = results.length === 0;
  for (const result of results) {
    const li = document.createElement("li");
    li.innerHTML = `<strong>${result.notebookTitle}</strong> — page ${result.pageIndex + 1}<br><small>${result.snippet}</small>`;
    li.addEventListener("click", async () => {
      await openNotebook(result.notebookId);
      selectPage(result.pageId);
    });
    searchResults.appendChild(li);
  }
}

// ---- Notebook view --------------------------------------------------------
async function openNotebook(notebookId) {
  const notebook = await Notebooks.get(notebookId);
  if (!notebook) return;

  await flushCurrentPageIfNeeded();

  currentNotebook = notebook;
  currentPage = null;
  notebookUndoStack = new UndoStack({ budgetBytes: NOTEBOOK_UNDO_BUDGET_BYTES });

  libraryView.hidden = true;
  notebookView.hidden = false;
  backButton.hidden = false;
  titleLabel.textContent = notebook.title;

  await renderPageList();
  if (notebook.pageOrder.length > 0) {
    await selectPage(notebook.pageOrder[0]);
  }
}

backButton.addEventListener("click", async () => {
  await flushCurrentPageIfNeeded();
  currentNotebook = null;
  currentPage = null;
  backButton.hidden = true;
  titleLabel.textContent = "Notebooks";
  notebookView.hidden = true;
  libraryView.hidden = false;
  renderLibrary();
});

async function renderPageList() {
  pageList.innerHTML = "";
  currentNotebook.pageOrder.forEach((pageId, index) => {
    const li = document.createElement("li");
    li.textContent = `Page ${index + 1}`;
    li.dataset.pageId = pageId;
    if (currentPage && currentPage.id === pageId) li.classList.add("active");
    li.addEventListener("click", () => selectPage(pageId));
    pageList.appendChild(li);
  });
}

async function flushCurrentPageIfNeeded() {
  if (currentPage) {
    await autosave.flush(currentPage.id);
  }
}

async function selectPage(pageId) {
  await flushCurrentPageIfNeeded();

  const page = await Pages.get(pageId);
  if (!page) return;
  currentPage = page;
  pageUndoStack = new UndoStack({ budgetBytes: PAGE_UNDO_BUDGET_BYTES });
  refreshUndoButtons();

  canvasView.setPageSize(US_LETTER_CSS.width, US_LETTER_CSS.height);
  canvasView.setStrokes(page.strokes);
  canvasView.setAnnotations(page.annotations);

  if (page.pdfPageIndex !== null && page.pdfPageIndex !== undefined) {
    const background = await renderPdfPageToCanvas(currentNotebook, page.pdfPageIndex);
    canvasView.setBackgroundImage(background);
  } else {
    canvasView.setBackgroundImage(null);
  }

  Array.from(pageList.children).forEach((li) => {
    li.classList.toggle("active", li.dataset.pageId === pageId);
  });
}

addPageButton.addEventListener("click", async () => {
  if (!currentNotebook) return;
  const page = createPage({ notebookId: currentNotebook.id });
  await Pages.put(page);

  const insertAfter = currentPage ? currentNotebook.pageOrder.indexOf(currentPage.id) : currentNotebook.pageOrder.length - 1;
  const insertIndex = insertAfter + 1;

  await notebookUndoStack.perform({
    estimatedByteCost: 256,
    redo: async () => {
      currentNotebook.pageOrder.splice(insertIndex, 0, page.id);
      currentNotebook.updatedAt = Date.now();
      await Notebooks.put(currentNotebook);
      renderPageList();
    },
    undo: async () => {
      currentNotebook.pageOrder = currentNotebook.pageOrder.filter((id) => id !== page.id);
      currentNotebook.updatedAt = Date.now();
      await Notebooks.put(currentNotebook);
      await Pages.delete(page.id);
      renderPageList();
    },
  });
  await selectPage(page.id);
});

deletePageButton.addEventListener("click", async () => {
  if (!currentNotebook || !currentPage) return;
  if (currentNotebook.pageOrder.length <= 1) {
    alert("A notebook needs at least one page.");
    return;
  }
  const removedId = currentPage.id;
  const removedIndex = currentNotebook.pageOrder.indexOf(removedId);
  const removedPage = currentPage;

  await notebookUndoStack.perform({
    estimatedByteCost: JSON.stringify(removedPage).length,
    redo: async () => {
      currentNotebook.pageOrder = currentNotebook.pageOrder.filter((id) => id !== removedId);
      currentNotebook.updatedAt = Date.now();
      await Notebooks.put(currentNotebook);
      await Pages.delete(removedId);
      renderPageList();
    },
    undo: async () => {
      currentNotebook.pageOrder.splice(removedIndex, 0, removedId);
      currentNotebook.updatedAt = Date.now();
      await Pages.put(removedPage);
      await Notebooks.put(currentNotebook);
      renderPageList();
    },
  });

  const nextPageId = currentNotebook.pageOrder[Math.min(removedIndex, currentNotebook.pageOrder.length - 1)];
  currentPage = null; // already removed, nothing to flush
  await selectPage(nextPageId);
});

exportButton.addEventListener("click", async () => {
  if (!currentNotebook) return;
  await flushCurrentPageIfNeeded();
  exportButton.disabled = true;
  exportButton.textContent = "Exporting…";
  try {
    await exportNotebookToPdf(currentNotebook, {
      onProgress: (done, total) => {
        exportButton.textContent = `Exporting ${done}/${total}…`;
      },
    });
  } finally {
    exportButton.disabled = false;
    exportButton.textContent = "Export PDF";
  }
});

// ---- Toolbar ---------------------------------------------------------------
const toolButtons = [penTool, eraserTool, textTool, moveTool];
toolButtons.forEach((button) => {
  button.addEventListener("click", () => {
    toolButtons.forEach((b) => b.classList.remove("active"));
    button.classList.add("active");
    canvasView.setTool(button.dataset.tool);
  });
});

// Inserting an image doesn't change the active drawing tool — the image lands at a
// default position and can then be repositioned with the Move tool, same as the
// Swift app's PhotosPicker flow inserting at a fixed frame.
imageInput.addEventListener("change", async (event) => {
  const file = event.target.files[0];
  event.target.value = "";
  if (!file || !currentPage) return;

  const bitmap = await createImageBitmap(file);
  const defaultWidth = 200;
  const aspect = bitmap.height / bitmap.width;
  const annotation = createImageAnnotation({
    x: 40,
    y: 40,
    width: defaultWidth,
    height: defaultWidth * aspect,
    imageBlob: file,
  });

  // Already decoded above for the aspect-ratio calculation — seed the cache so
  // addAnnotationInternal doesn't decode the same bytes a second time.
  canvasView._imageBitmapCache.set(annotation.id, bitmap);

  await pageUndoStack.perform({
    estimatedByteCost: file.size,
    redo: () => canvasView.addAnnotationInternal(annotation),
    undo: () => canvasView.removeAnnotationInternal(annotation.id),
  });
  commitPageContentChange();
});

colorPicker.addEventListener("input", () => canvasView.setColor(colorPicker.value));
widthPicker.addEventListener("input", () => canvasView.setWidth(Number(widthPicker.value)));

undoButton.addEventListener("click", async () => {
  await pageUndoStack.undo();
  commitPageContentChange();
});
redoButton.addEventListener("click", async () => {
  await pageUndoStack.redo();
  commitPageContentChange();
});

// Page exit / app backgrounding equivalent (§5 note 4): flush immediately rather than
// waiting out the debounce window.
window.addEventListener("beforeunload", () => {
  if (currentPage) autosave.flush(currentPage.id);
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushCurrentPageIfNeeded();
});

// ---- Boot -------------------------------------------------------------------
renderLibrary();
