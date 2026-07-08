import { Notebooks, Pages } from "./db.js";
import { extractPdfPageText } from "./pdfImport.js";

// Search — the web analogue of §8, scaled down for a single-browser test harness: no
// persistent FTS5 index, just an on-demand scan with an in-memory text cache keyed by
// contentHash (same idempotency idea as the Swift app's index: unchanged content never
// gets re-extracted).
const textCache = new Map(); // pageId -> { hash, text }

async function pageSearchText(notebook, page) {
  const cached = textCache.get(page.id);
  if (cached && cached.hash === page.contentHash) return cached.text;

  const parts = page.annotations.map((a) => a.text || "").filter(Boolean);
  if (page.pdfPageIndex !== null && page.pdfPageIndex !== undefined) {
    try {
      const pdfText = await extractPdfPageText(notebook, page.pdfPageIndex);
      if (pdfText) parts.push(pdfText);
    } catch {
      // PDF text extraction failing shouldn't break search for the rest of the page.
    }
  }
  const text = parts.join("\n");
  textCache.set(page.id, { hash: page.contentHash, text });
  return text;
}

export async function searchAll(query) {
  const trimmed = query.trim();
  if (!trimmed) return [];
  const needle = trimmed.toLowerCase();

  const notebooks = await Notebooks.getAll();
  const results = [];

  for (const notebook of notebooks) {
    const pages = await Pages.getAllForNotebook(notebook.id);
    for (const page of pages) {
      const text = await pageSearchText(notebook, page);
      const index = text.toLowerCase().indexOf(needle);
      if (index === -1) continue;
      const start = Math.max(0, index - 30);
      const snippet = (start > 0 ? "…" : "") + text.slice(start, index + needle.length + 30) + "…";
      results.push({
        notebookId: notebook.id,
        notebookTitle: notebook.title,
        pageId: page.id,
        pageIndex: notebook.pageOrder.indexOf(page.id),
        snippet,
      });
    }
  }
  return results;
}
