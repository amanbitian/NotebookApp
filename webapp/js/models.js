// Record shapes — the web analogue of Manifest.swift / PageMeta.swift / Page.swift.
// There is no on-disk package format here (IndexedDB is the only store, §3/§4's
// synced-vs-local split doesn't apply to a single browser), but the *shape* of the
// data — stable page UUIDs, order kept separately from content, vector strokes rather
// than raster — carries over deliberately.

import { sha256Hex } from "./hash.js";

export const CURRENT_FORMAT_VERSION = 1;

export function newId() {
  return crypto.randomUUID();
}

export function createNotebook({ title, sourcePdf = null, pageOrder = [] }) {
  const now = Date.now();
  return {
    id: newId(),
    formatVersion: CURRENT_FORMAT_VERSION,
    title,
    sourcePdf, // ArrayBuffer of the original PDF, immutable once imported (§3.1 parity)
    pageOrder, // order lives here, never inferred from page records (§3.1 parity)
    createdAt: now,
    updatedAt: now,
  };
}

export function createPage({ id = newId(), notebookId, pdfPageIndex = null }) {
  return {
    id,
    notebookId,
    pdfPageIndex, // index into the notebook's sourcePdf, or null for a blank page
    strokes: [], // vector strokes — never rasterized until export
    annotations: [], // { id, kind: "text"|"image", x, y, width, height, text?, imageBlob? }
    lastModified: Date.now(),
    contentHash: "",
  };
}

export function createStroke({ tool, color, width }) {
  return {
    id: newId(),
    tool, // "pen" | "eraser"
    color,
    width,
    points: [], // { x, y, pressure }
  };
}

// Image annotations are user content, not derived data — same rationale as the Swift
// app storing inserted images as real files in the synced package rather than a
// disposable cache. `imageBlob` is an IndexedDB-native Blob, structured-cloned
// straight into the page record (no separate "images" store needed).
export function createImageAnnotation({ id = newId(), x, y, width, height, imageBlob }) {
  return { id, kind: "image", x, y, width, height, imageBlob };
}

export function createTextAnnotation({ id = newId(), x, y, text }) {
  return { id, kind: "text", x, y, width: null, height: null, text };
}

// Stable content for hashing: strokes + annotations, not lastModified/contentHash
// themselves (mirrors hashing the serialized drawing bytes, not the metadata).
// `imageBlob` isn't JSON-serializable, so each image annotation is fingerprinted by
// hashing its actual bytes first — matching the Swift app's "hash the real serialized
// bytes" approach rather than approximating on size/type, which would have missed a
// same-size same-type image swapped in under an unchanged annotation id.
export async function stableContentString(page) {
  const hashableAnnotations = await Promise.all(
    page.annotations.map(async (a) => {
      if (a.kind !== "image") return a;
      const fingerprint = a.imageBlob ? await sha256Hex(new Uint8Array(await a.imageBlob.arrayBuffer())) : null;
      return { id: a.id, kind: a.kind, x: a.x, y: a.y, width: a.width, height: a.height, fingerprint };
    })
  );
  return JSON.stringify({ strokes: page.strokes, annotations: hashableAnnotations });
}
