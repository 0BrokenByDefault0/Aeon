/* Read-only bridge from Aeon's 4.x IndexedDB catalogue into the native
   migration coordinator. This page never renders application UI. */
(() => {
  "use strict";

  const DATABASE = "isolation-db";
  const STORES = ["albums", "tracks", "playlists", "kv"];
  const PAGE_SIZE = 250;

  function plugin() {
    const value = window.Capacitor && window.Capacitor.Plugins
      && window.Capacitor.Plugins.LegacyMigration;
    if (!value) throw new Error("Legacy migration bridge unavailable");
    return value;
  }

  function openExistingDatabase() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(DATABASE);
      request.onupgradeneeded = () => {
        request.transaction.abort();
        reject(new Error("Legacy catalogue not found"));
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("Legacy catalogue unavailable"));
      request.onblocked = () => reject(new Error("Legacy catalogue is busy"));
    });
  }

  function requestValue(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("IndexedDB request failed"));
    });
  }

  async function storeCount(database, name) {
    const transaction = database.transaction(name, "readonly");
    return requestValue(transaction.objectStore(name).count());
  }

  function stableID(store, record) {
    const value = store === "kv" ? record && record.k : record && record.id;
    return typeof value === "string" ? value : "";
  }

  function blobDescriptor(store, record) {
    if (store === "albums" && record && record.art instanceof Blob) {
      return {
        ownerID: stableID(store, record),
        kind: "artwork",
        byteLength: record.art.size,
        mediaType: record.art.type || "application/octet-stream",
        fileName: ""
      };
    }
    if (store === "tracks" && record && record.blob instanceof Blob) {
      return {
        ownerID: stableID(store, record),
        kind: "audio",
        byteLength: record.blob.size,
        mediaType: record.blob.type || "application/octet-stream",
        fileName: typeof record.blob.name === "string" ? record.blob.name : ""
      };
    }
    return null;
  }

  function recordWithoutBlobs(record) {
    const value = {};
    for (const [key, field] of Object.entries(record || {})) {
      if (!(field instanceof Blob)) value[key] = field;
    }
    return value;
  }

  async function scanStore(database, name, bridge) {
    let page = 0;
    let afterKey;
    for (;;) {
      const range = afterKey === undefined ? undefined : IDBKeyRange.lowerBound(afterKey, true);
      const transaction = database.transaction(name, "readonly");
      const records = await requestValue(transaction.objectStore(name).getAll(range, PAGE_SIZE));
      const ids = [];
      const blobs = [];
      const values = [];
      for (const record of records) {
        const id = stableID(name, record);
        if (!id) throw new Error(`Legacy ${name} record has no stable ID`);
        ids.push(id);
        values.push(recordWithoutBlobs(record));
        const descriptor = blobDescriptor(name, record);
        if (descriptor) blobs.push(descriptor);
      }
      const isLast = records.length < PAGE_SIZE;
      await bridge.reportPage({ store: name, page, ids, records: values, blobs, isLast });
      page += 1;
      if (isLast) return;
      afterKey = ids[ids.length - 1];
    }
  }

  async function run() {
    const bridge = plugin();
    let database;
    try {
      database = await openExistingDatabase();
      for (const name of STORES) {
        if (!database.objectStoreNames.contains(name)) {
          throw new Error(`Legacy catalogue is missing ${name}`);
        }
      }
      const counts = {};
      for (const name of STORES) counts[name] = await storeCount(database, name);
      await bridge.reportInventory({
        databaseName: DATABASE,
        schemaVersion: database.version,
        counts
      });
      for (const name of STORES) await scanStore(database, name, bridge);
      await bridge.finishInventory({});
    } catch (error) {
      try {
        await bridge.reportFailure({
          code: "legacy_inventory_failed",
          message: error && error.message ? error.message : "Legacy catalogue unavailable"
        });
      } catch (_) {}
    } finally {
      if (database) database.close();
    }
  }

  window.AeonLegacyMigration = { run, pageSize: PAGE_SIZE, stores: STORES.slice() };
  run();
})();
