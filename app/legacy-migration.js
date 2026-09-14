/* Read-only bridge from Aeon's 4.x IndexedDB catalogue into the native
   migration coordinator. This page never renders application UI. */
(() => {
  "use strict";

  const DATABASE = "isolation-db";
  const STORES = ["albums", "tracks", "playlists", "kv"];
  const PAGE_SIZE = 250;
  const CHUNK_SIZE = 512 * 1024;

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
    const foundBlobs = [];
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
        if (descriptor) { blobs.push(descriptor); foundBlobs.push(descriptor); }
      }
      const isLast = records.length < PAGE_SIZE;
      await bridge.reportPage({ store: name, page, ids, records: values, blobs, isLast });
      page += 1;
      if (isLast) return foundBlobs;
      afterKey = ids[ids.length - 1];
    }
  }

  function updateCRC32(crc, bytes) {
    for (const byte of bytes) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    return crc >>> 0;
  }

  function bytesBase64(bytes) {
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(offset, Math.min(bytes.length, offset + 0x8000)));
    }
    return btoa(binary);
  }

  async function readArtifact(database, descriptor) {
    const store = descriptor.kind === "artwork" ? "albums" : "tracks";
    const transaction = database.transaction(store, "readonly");
    const record = await requestValue(transaction.objectStore(store).get(descriptor.ownerID));
    const blob = record && (descriptor.kind === "artwork" ? record.art : record.blob);
    if (!(blob instanceof Blob) || blob.size !== descriptor.byteLength) {
      throw new Error(`Legacy ${descriptor.kind} changed during migration`);
    }
    return blob;
  }

  async function streamArtifact(database, descriptor, bridge, runID) {
    const artifactID = `${descriptor.kind}:${descriptor.ownerID}`;
    const resume = await bridge.beginArtifact({runID, artifactID, ...descriptor});
    if (resume && resume.complete) return;
    const blob = await readArtifact(database, descriptor);
    const nextOffset = Number(resume && resume.nextOffset) || 0;
    let sequence = 0;
    let crc = 0xffffffff;
    for (let offset = 0; offset < blob.size; offset += CHUNK_SIZE) {
      const bytes = new Uint8Array(await blob.slice(offset, Math.min(blob.size, offset + CHUNK_SIZE)).arrayBuffer());
      crc = updateCRC32(crc, bytes);
      if (offset >= nextOffset) {
        const accepted = await bridge.reportArtifactChunk({
          runID, artifactID, sequence, offset, bytesBase64: bytesBase64(bytes),
          crc32: (updateCRC32(0xffffffff, bytes) ^ 0xffffffff) >>> 0
        });
        if (!accepted || accepted.nextOffset !== offset + bytes.length) {
          throw new Error(`Native ${descriptor.kind} checkpoint was not accepted`);
        }
      }
      sequence += 1;
      await new Promise(resolve => setTimeout(resolve, 0));
    }
    await bridge.finishArtifact({runID, artifactID, byteLength: blob.size, crc32: (crc ^ 0xffffffff) >>> 0});
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
      const blobs = [];
      for (const name of STORES) blobs.push(...await scanStore(database, name, bridge));
      await bridge.finishInventory({});
      const runID = `${DATABASE}:v${database.version}`;
      const lastPlayed = await requestValue(database.transaction("kv", "readonly").objectStore("kv").get("lastPlayed"));
      const priority = new Map((((lastPlayed && lastPlayed.v && lastPlayed.v.queue) || [])).map((item, index) => [item.trackId, index]));
      for (const kind of ["artwork", "audio"]) {
        const ordered = blobs.filter(value => value.kind === kind).sort((a, b) =>
          (priority.get(a.ownerID) ?? Number.MAX_SAFE_INTEGER) - (priority.get(b.ownerID) ?? Number.MAX_SAFE_INTEGER));
        for (const descriptor of ordered) {
          await streamArtifact(database, descriptor, bridge, runID);
        }
      }
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

  window.AeonLegacyMigration = { run, pageSize: PAGE_SIZE, chunkSize: CHUNK_SIZE, stores: STORES.slice() };
  run();
})();
