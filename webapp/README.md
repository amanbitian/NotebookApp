# webapp — browser test harness for the SYSTEM_DESIGN.md architecture

A zero-build-step vanilla JS/HTML/CSS implementation of the same core note-taking loop
as the Swift/PencilKit app in the parent directory (`..`), so you can exercise it in a
browser on Windows — where the Swift app can't even compile. This is a **test harness
for the core experience**, not a port of the full architecture. See "What's
deliberately not here" below before assuming feature parity. The design doc both apps
implement is `../../SYSTEM_DESIGN.md`.

## Running it

IndexedDB and ES modules both work better served over `http://` than opened directly
as a `file://` URL (module `import`/`export` is blocked under `file://` in most
browsers). From this directory:

```
python -m http.server 8000
```

Then open `http://localhost:8000` in any modern desktop browser (Chrome/Edge/Firefox).
No npm install, no build step — `index.html` loads pdf.js and jsPDF from a CDN via
plain `<script>` tags, and the app's own code is plain ES modules under `js/`.

## What's here, mapped to the design doc

| Design doc concept | Web equivalent |
|---|---|
| §3 synced package + local derived state | Collapsed into one IndexedDB database (`js/db.js`) — a single browser has nothing to sync with, so the synced/local split doesn't apply |
| §4 manifest | `js/models.js` — notebook record with `pageOrder` kept separate from page content, stable UUIDs, `formatVersion` field (unenforced — see below) |
| §5 autosave pipeline | `js/autosave.js` — debounced writes, flush-on-page-exit/tab-hide, same "mark dirty cheaply, serialize later" shape |
| §5 undo (two scopes) | `js/undoStack.js` — one instance per open page (ink/annotations), one per notebook (page insert/delete), same memory-based eviction policy |
| §2 render path (PencilKit) | `js/canvasView.js` — Pointer Events + `<canvas>`, vector strokes (not raster) rendered on every change |
| §9 import/export | `js/pdfImport.js` (pdf.js) / `js/pdfExport.js` (jsPDF) — same "one page at a time" rendering shape as `ExportJob.swift`, and `pdfExport.js` reuses the same stroke-drawing function the live canvas uses, mirroring the Swift app's `ExportJob`/backup-scheduler code reuse |
| §8 search | `js/search.js` — on-demand scan with an in-memory per-page text cache keyed by `contentHash`, same idempotency idea as the Swift FTS5 index, minus the persistent index itself |
| Image annotations | `js/models.js` (`createImageAnnotation`), rendering/drag/erase in `js/canvasView.js`, insertion flow in `js/app.js` ("+ Image" button, "Move" tool), drawn into export in `js/pdfExport.js` |

**Inserting images:** pick "+ Image" to add a photo at a default position/size, switch
to the "Move" tool to drag it (or a text annotation) around, or use the eraser to
remove it — same three interactions the eraser already had for ink. Images are stored
as `Blob`s directly inside the page's IndexedDB record (structured-clone handles
`Blob`/`File` natively, no separate object store needed). This also surfaced a real gap
while building it: `pdfExport.js` previously didn't draw *any* annotations, not just
images — text annotations were silently dropped from every export. Both kinds are
drawn now.

## What's deliberately not here

This harness exists to let you poke at drawing, pages, undo, autosave, import, and
export on a machine that can't run the real app. It does **not** reimplement:

- **§6 sync engine / iCloud / Google Drive.** No second device, no cloud backend —
  there is nothing to sync with in a single browser tab. `sourcePdf` and page content
  just live in IndexedDB.
- **§7 conflict detection and 3-way merge.** Conflicts only exist when two writers
  diverge from a common ancestor; a single local store has no such scenario.
- **§4 rule 1's format-version gate.** `formatVersion` is stored but nothing checks it
  on load — there's only ever one version of this code reading the data, so there's no
  "future format" case to defend against yet.
- **Partial-eraser stroke splitting (§7.3).** The eraser here removes whole strokes
  that it touches; PencilKit's segment-splitting eraser behavior (and the merge
  wrinkle it creates) isn't reproduced.
- **Handwriting OCR (§8/§13 v1.2).** Search only covers typed text annotations and the
  PDF's existing text layer (via pdf.js), not the ink itself.
- Pressure-sensitive rendering, palm rejection, and anything else that depends on an
  actual stylus — this runs on mouse/trackpad/touch via Pointer Events, which is
  sufficient for testing app logic but won't feel like a real pencil.

## Known rough edges

- Export renders ink as a single flattened JPEG per page (via `canvas.toDataURL`)
  rather than vector paths in the PDF — simpler than teaching jsPDF to draw quadratic
  curves, at the cost of some fidelity/file size versus the Swift app's PDFKit-based
  export.
- No PDF worker fallback if the CDN is unreachable — this needs internet access on
  first load (browsers will cache it after).
- Resize only works for image annotations (drag the blue corner handle with the
  "Move" tool selected), not text — matching the Swift app's edit sheet, which is
  also image-only.

### Fixed since first cut

- `undo`/`redo` fired their IndexedDB writes without awaiting them (page
  insert/delete, and every ink/annotation command via `UndoStack`). `UndoStack.perform/
  undo/redo` are now `async` and every call site awaits them — worth noting *why* this
  mattered: `await` on a plain non-Promise value still defers to a microtask in JS, so
  making these methods `async` without updating every call site would have introduced
  a one-tick lag between an action and `refreshUndoButtons()` seeing it. All six call
  sites in `app.js` were updated together with the `UndoStack` change.
- The content hash used for autosave/search dedup only covered an image's byte size
  and MIME type, not its actual bytes. `stableContentString` now hashes each image
  annotation's real bytes (async, via `crypto.subtle.digest`), matching the Swift
  app's approach.
- The in-memory decoded-image cache (`CanvasView._imageBitmapCache`) wasn't cleared
  when switching pages, so it grew for the life of the tab. `setAnnotations` (only
  ever called on page open/switch) now clears it first.
- Image annotations were move/delete only. Resize now works too: with the "Move" tool
  active, a small blue handle appears on the bottom-right corner of each image; drag
  it to resize (aspect-locked), tracked through the same undo stack as move.
