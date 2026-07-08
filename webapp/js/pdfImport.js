import { Notebooks, Pages } from "./db.js";
import { createNotebook, createPage } from "./models.js";

// pdf.js is loaded globally via the CDN <script> tag in index.html (UMD build), not
// as an ES import — keeps the app runnable with zero build step.
const pdfjsLib = window.pdfjsLib;
pdfjsLib.GlobalWorkerOptions.workerSrc =
  "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js";

const US_LETTER_CSS = { width: 850, height: 1100 };

// PDF documents are cached by notebookId for the session — re-parsing pdf.js from the
// stored ArrayBuffer on every page open would be wasteful. This is in-memory only
// (analogous to the disposable, regenerate-on-miss thumbnail cache in §3.2), never
// the source of truth — `notebook.sourcePdf` in IndexedDB is.
const openDocuments = new Map();

export async function getPdfDocument(notebook) {
  if (!notebook.sourcePdf) return null;
  if (openDocuments.has(notebook.id)) return openDocuments.get(notebook.id);
  const loadingTask = pdfjsLib.getDocument({ data: notebook.sourcePdf.slice(0) });
  const doc = await loadingTask.promise;
  openDocuments.set(notebook.id, doc);
  return doc;
}

export function forgetPdfDocument(notebookId) {
  openDocuments.delete(notebookId);
}

// Import as a brand-new notebook (§9 parity: "PDF -> copy as source.pdf, create page
// UUIDs + manifest"). `source.pdf` bytes are stored once and never rewritten.
export async function importPdfFile(file) {
  const arrayBuffer = await file.arrayBuffer();
  const doc = await pdfjsLib.getDocument({ data: arrayBuffer.slice(0) }).promise;
  const pageCount = doc.numPages;

  const pageOrder = [];
  const notebook = createNotebook({
    title: file.name.replace(/\.pdf$/i, ""),
    sourcePdf: arrayBuffer,
  });

  const pages = [];
  for (let i = 0; i < pageCount; i++) {
    const page = createPage({ notebookId: notebook.id, pdfPageIndex: i });
    pages.push(page);
    pageOrder.push(page.id);
  }
  notebook.pageOrder = pageOrder;

  await Notebooks.put(notebook);
  await Promise.all(pages.map((p) => Pages.put(p)));
  return notebook;
}

export function createBlankNotebook(title) {
  const notebook = createNotebook({ title });
  const page = createPage({ notebookId: notebook.id });
  notebook.pageOrder = [page.id];
  return { notebook, page };
}

// Renders a PDF page to an offscreen canvas for use as a page background. Lazy —
// only called for the page currently being viewed (§11 parity: "Open = manifest +
// visible pages only").
export async function renderPdfPageToCanvas(notebook, pdfPageIndex, cssSize = US_LETTER_CSS) {
  const doc = await getPdfDocument(notebook);
  if (!doc) return null;
  const page = await doc.getPage(pdfPageIndex + 1); // pdf.js pages are 1-indexed
  const baseViewport = page.getViewport({ scale: 1 });
  const scale = Math.min(cssSize.width / baseViewport.width, cssSize.height / baseViewport.height);
  const dpr = window.devicePixelRatio || 1;
  const viewport = page.getViewport({ scale: scale * dpr });

  const canvas = document.createElement("canvas");
  canvas.width = viewport.width;
  canvas.height = viewport.height;
  const ctx = canvas.getContext("2d");
  await page.render({ canvasContext: ctx, viewport }).promise;
  return canvas;
}

export async function extractPdfPageText(notebook, pdfPageIndex) {
  const doc = await getPdfDocument(notebook);
  if (!doc) return "";
  const page = await doc.getPage(pdfPageIndex + 1);
  const textContent = await page.getTextContent();
  return textContent.items.map((item) => item.str).join(" ");
}

export { US_LETTER_CSS };
