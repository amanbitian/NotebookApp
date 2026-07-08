import { Pages } from "./db.js";
import { renderPdfPageToCanvas, US_LETTER_CSS } from "./pdfImport.js";
import { drawStrokeOnContext } from "./canvasView.js";

// Flattened-PDF export — the web analogue of ExportJob.swift (§9): one page in flight
// at a time, rendered to an offscreen canvas and handed to jsPDF, so memory stays
// bounded regardless of notebook length.
export async function exportNotebookToPdf(notebook, { onProgress } = {}) {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF({ unit: "px", format: [US_LETTER_CSS.width, US_LETTER_CSS.height] });

  for (let i = 0; i < notebook.pageOrder.length; i++) {
    const pageId = notebook.pageOrder[i];
    const page = await Pages.get(pageId);
    if (!page) continue;

    const canvas = document.createElement("canvas");
    canvas.width = US_LETTER_CSS.width;
    canvas.height = US_LETTER_CSS.height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, US_LETTER_CSS.width, US_LETTER_CSS.height);

    if (page.pdfPageIndex !== null && page.pdfPageIndex !== undefined) {
      const background = await renderPdfPageToCanvas(notebook, page.pdfPageIndex, US_LETTER_CSS);
      if (background) ctx.drawImage(background, 0, 0, US_LETTER_CSS.width, US_LETTER_CSS.height);
    }

    for (const stroke of page.strokes) {
      drawStrokeOnContext(ctx, stroke);
    }

    for (const annotation of page.annotations) {
      await drawAnnotationForExport(ctx, annotation);
    }

    if (i > 0) doc.addPage([US_LETTER_CSS.width, US_LETTER_CSS.height], "portrait");
    doc.addImage(canvas.toDataURL("image/jpeg", 0.92), "JPEG", 0, 0, US_LETTER_CSS.width, US_LETTER_CSS.height);

    onProgress?.(i + 1, notebook.pageOrder.length);
  }

  doc.save(`${notebook.title || "notebook"}.pdf`);
}

// This was previously missing entirely — flattened exports silently dropped every
// text box and inserted image. Decoding happens fresh per export rather than reusing
// CanvasView's in-memory bitmap cache, since export runs against whatever page was
// last persisted, not necessarily the currently-open one.
async function drawAnnotationForExport(ctx, annotation) {
  if (annotation.kind === "image") {
    if (!annotation.imageBlob) return;
    try {
      const bitmap = await createImageBitmap(annotation.imageBlob);
      ctx.drawImage(bitmap, annotation.x, annotation.y, annotation.width, annotation.height);
    } catch {
      // Corrupt/unreadable image blob shouldn't abort the whole export.
    }
    return;
  }
  ctx.fillStyle = "#1a1a1a";
  ctx.font = "16px sans-serif";
  ctx.textBaseline = "top";
  ctx.fillText(annotation.text, annotation.x, annotation.y);
}
