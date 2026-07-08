import { Pages } from "./db.js";
import { sha256Hex } from "./hash.js";
import { stableContentString } from "./models.js";

// Debounced write path — the web analogue of AutosavePipeline.swift (§5). No
// separate "journal" table: IndexedDB's own transaction is the atomic write, and since
// there's only one device involved, there's nothing to reconcile a journal against.
export class AutosavePipeline {
  constructor({ debounceMs = 800, onFlushed } = {}) {
    this.debounceMs = debounceMs;
    this.onFlushed = onFlushed || (() => {});
    this._timers = new Map(); // pageId -> timeout handle
    this._dirty = new Map(); // pageId -> page object (latest in-memory state)
  }

  // Cheap: just marks dirty and (re)starts the debounce timer. Called on every
  // stroke/annotation change, mirroring "never serialize inside the change callback".
  markDirty(page) {
    this._dirty.set(page.id, page);
    clearTimeout(this._timers.get(page.id));
    this._timers.set(
      page.id,
      setTimeout(() => this.flush(page.id), this.debounceMs)
    );
  }

  async flush(pageId) {
    const page = this._dirty.get(pageId);
    if (!page) return;
    clearTimeout(this._timers.get(pageId));
    this._timers.delete(pageId);
    this._dirty.delete(pageId);

    page.lastModified = Date.now();
    // stableContentString is async: image annotations are fingerprinted by hashing
    // their actual bytes, not approximated from size/type (§8 parity with the Swift
    // app's SHA-256-of-serialized-bytes approach).
    page.contentHash = await sha256Hex(await stableContentString(page));
    await Pages.put(page);
    this.onFlushed(page);
  }

  async flushAll() {
    const pending = Array.from(this._dirty.keys());
    await Promise.all(pending.map((id) => this.flush(id)));
  }

  hasPending() {
    return this._dirty.size > 0;
  }
}
