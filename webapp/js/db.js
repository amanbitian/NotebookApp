// Local-first storage (P1/P2 parity): IndexedDB is the single source of truth here.
// There's no synced-package vs. local-derived-state split like §3 — a single browser
// has nothing to sync with — so notebooks and pages just live in one database.

const DB_NAME = "notebook-app";
const DB_VERSION = 1;

let dbPromise = null;

function openDatabase() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("notebooks")) {
        db.createObjectStore("notebooks", { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains("pages")) {
        const pages = db.createObjectStore("pages", { keyPath: "id" });
        pages.createIndex("notebookId", "notebookId", { unique: false });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return dbPromise;
}

function tx(storeName, mode) {
  return openDatabase().then((db) => db.transaction(storeName, mode).objectStore(storeName));
}

function wrap(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export const Notebooks = {
  async put(notebook) {
    const store = await tx("notebooks", "readwrite");
    await wrap(store.put(notebook));
  },
  async get(id) {
    const store = await tx("notebooks", "readonly");
    return wrap(store.get(id));
  },
  async getAll() {
    const store = await tx("notebooks", "readonly");
    return wrap(store.getAll());
  },
  async delete(id) {
    const store = await tx("notebooks", "readwrite");
    await wrap(store.delete(id));
  },
};

export const Pages = {
  async put(page) {
    const store = await tx("pages", "readwrite");
    await wrap(store.put(page));
  },
  async get(id) {
    const store = await tx("pages", "readonly");
    return wrap(store.get(id));
  },
  async getAllForNotebook(notebookId) {
    const store = await tx("pages", "readonly");
    const index = store.index("notebookId");
    return wrap(index.getAll(notebookId));
  },
  async delete(id) {
    const store = await tx("pages", "readwrite");
    await wrap(store.delete(id));
  },
  async deleteAllForNotebook(notebookId) {
    const pages = await Pages.getAllForNotebook(notebookId);
    await Promise.all(pages.map((p) => Pages.delete(p.id)));
  },
};
