# Aeon Security and Reliability Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve every approved Aeon audit finding without replacing the single-file application architecture.

**Architecture:** Keep the shipped app in `app/index.html`, but collect deterministic backup, MIME, grouping, restore-validation, and queue helpers in an inline `AeonCore` module so Node can execute the same production functions in regression tests. Apply restore data in one IndexedDB transaction, stream ZIP input/output through `Blob` slices, and replace executable JSONP with CORS/native HTTP data requests gated by an explicit metadata setting.

**Tech Stack:** HTML/CSS/vanilla JavaScript PWA, IndexedDB, Web Streams/Blob APIs, Capacitor 6, Node's built-in test runner, GitHub Actions.

## Global Constraints

- Preserve the existing single-file PWA architecture and visual language.
- Keep user audio, artwork, playlists, history, and settings on-device.
- Make background metadata enrichment opt-in and keep manual lookups explicit.
- Accept valid version-1 backups while exporting version 2.
- Never mutate persistent or in-memory library state until the complete backup validates.
- Commit and push directly to `claude/music-collection-gateway-e5ln7f`, the repository default branch, as previously approved.

---

### Task 1: Executable regression harness and deterministic core

**Files:**
- Modify: `app/index.html`
- Create: `tests/aeon-core.test.cjs`
- Create: `scripts/check-syntax.cjs`
- Modify: `package.json`

**Interfaces:**
- Consumes: the inline script between `/* AEON_CORE_START */` and `/* AEON_CORE_END */`.
- Produces: `AeonCore.mimeForFilename`, `AeonCore.extensionForBlob`, `AeonCore.groupItems`, `AeonCore.validateBackupCatalog`, `AeonCore.mergeLogEntries`, `AeonCore.scrubQueueForAlbum`, `AeonCore.zipWrite`, and `AeonCore.unzip`.

- [ ] **Step 1: Write failing behavior tests**

```js
test("keeps similarly named albums by different artists separate", () => {
  const groups = core.groupItems([
    tagged("Live", "Artist One"),
    tagged("Live at Wembley", "Artist Two")
  ], "smart");
  assert.equal(groups.length, 2);
});

test("rejects a backup with missing audio before restore", () => {
  assert.throws(
    () => core.validateBackupCatalog(catalog, new Set(["isolation-backup.json"])),
    /missing audio/i
  );
});
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `node --test tests/aeon-core.test.cjs`

Expected: FAIL because the `AEON_CORE` production module does not exist yet.

- [ ] **Step 3: Add the minimal inline core and syntax checker**

```js
const AeonCore = (() => {
  const MIME = {
    mp3: "audio/mpeg", m4a: "audio/mp4", aac: "audio/aac",
    flac: "audio/flac", wav: "audio/wav", ogg: "audio/ogg", opus: "audio/opus"
  };
  function mimeForFilename(name) {
    const match = String(name || "").toLowerCase().match(/\.([a-z0-9]+)$/);
    return match ? MIME[match[1]] || "application/octet-stream" : "application/octet-stream";
  }
  function groupKey(item) {
    const title = normAlbum(item.meta.album);
    const artist = normKey(item.meta.albumArtist || item.meta.artist || item.folder);
    return title ? `alb:${artist}:${title}` : `dir:${normKey(item.folder)}`;
  }
  function groupItems(items, mode) {
    if (mode !== "smart") return [items];
    const groups = new Map();
    for (const item of items) {
      const key = groupKey(item);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }
    return [...groups.values()];
  }
  function validateBackupCatalog(raw, entryNames) {
    if (!raw || ![1, 2].includes(raw.v) || !Array.isArray(raw.albums)) throw new Error("Unsupported backup version");
    for (const album of raw.albums) for (const track of album.tracks || []) {
      if (track.file && !entryNames.has(track.file)) throw new Error(`Backup is missing audio: ${track.file}`);
    }
    return raw;
  }
  return { mimeForFilename, groupItems, validateBackupCatalog };
})();
```

The syntax checker must compile every inline script with `vm.Script` and compile `app/sw.js` without executing browser code.

- [ ] **Step 4: Run focused tests and syntax checks**

Run: `npm test && npm run check`

Expected: all core tests pass and both shipped JavaScript files compile.

---

### Task 2: Low-memory, truthful backup export and format preservation

**Files:**
- Modify: `app/index.html`
- Test: `tests/aeon-core.test.cjs`

**Interfaces:**
- Consumes: album artwork and track `Blob`/`File` objects.
- Produces: a version-2 stored ZIP whose parts reference source blobs, with streamed CRC calculation and preserved `name`/`type` metadata.

- [ ] **Step 1: Add failing ZIP and MIME tests**

```js
test("writes a valid stored ZIP without materializing whole source blobs", async () => {
  const source = new Blob([Uint8Array.from([1, 2, 3, 4])], { type: "audio/flac" });
  source.arrayBuffer = () => { throw new Error("whole blob copied"); };
  const zip = await core.zipWrite([{ name: "audio/track.flac", blob: source }]);
  const entries = await core.unzip(zip);
  assert.deepEqual(new Uint8Array(await entries[0].blob.arrayBuffer()), Uint8Array.from([1, 2, 3, 4]));
});

test("maps every supported audio extension to its real MIME type", () => {
  assert.equal(core.mimeForFilename("song.flac"), "audio/flac");
  assert.equal(core.mimeForFilename("song.m4a"), "audio/mp4");
  assert.equal(core.mimeForFilename("song.wav"), "audio/wav");
});
```

- [ ] **Step 2: Verify RED against the current array-buffer ZIP writer**

Run: `node --test tests/aeon-core.test.cjs --test-name-pattern='ZIP|MIME|blob'`

Expected: FAIL because current export materializes each audio file and assigns ZIP audio `audio/mpeg`.

- [ ] **Step 3: Implement streamed CRC/Blob ZIP and truthful save handling**

```js
const saved = await saveBlob(await AeonCore.zipWrite(files), name);
if (!saved) {
  note.textContent = "Backup was packed but not saved.";
  return false;
}
```

Store `track.name` and `track.type` in schema v2; preserve old-backup extensions from the archive path. Treat share-sheet cancellation as not saved, and never log backup success after a failed/cancelled handoff.

- [ ] **Step 4: Verify GREEN**

Run: `npm test && npm run check`

Expected: the ZIP round-trip, no-whole-blob-copy, MIME, and save-result tests pass.

---

### Task 3: Validated transactional full restore

**Files:**
- Modify: `app/index.html`
- Test: `tests/aeon-core.test.cjs`

**Interfaces:**
- Consumes: validated backup catalog plus archive entry map.
- Produces: one atomic update across `albums`, `tracks`, `playlists`, and `kv`, repairing matching album IDs and restoring `skySeed`, `log`, play counts, settings, transit history, and valid last-played state.

- [ ] **Step 1: Add failing validation and merge tests**

```js
test("rejects future schemas and duplicate track IDs", () => {
  assert.throws(() => core.validateBackupCatalog({ v: 99, albums: [] }, new Set()), /version/i);
  assert.throws(() => core.validateBackupCatalog(duplicateTracks, entryNames), /duplicate track/i);
});

test("merges restored log entries without duplicating existing events", () => {
  assert.deepEqual(core.mergeLogEntries([event], [event, later]), [event, later]);
});
```

- [ ] **Step 2: Verify RED**

Run: `node --test tests/aeon-core.test.cjs --test-name-pattern='backup|schema|log'`

Expected: FAIL on missing validation and merge behavior.

- [ ] **Step 3: Validate first, then commit one database transaction**

```js
const cat = AeonCore.validateBackupCatalog(parsed, new Set(entries.keys()));
const plan = buildRestorePlan(cat, entries);
await dbRestoreAtomic(plan);
applyRestorePlanToState(plan);
```

Matching album IDs are replaced from the backup instead of skipped; obsolete tracks for those albums are deleted. Any missing audio, unsafe archive path, malformed entity, unsupported version, or duplicate ID aborts before `dbRestoreAtomic`.

- [ ] **Step 4: Verify GREEN**

Run: `npm test && npm run check`

Expected: all restore validation and merge tests pass.

---

### Task 4: Queue deletion and album grouping correctness

**Files:**
- Modify: `app/index.html`
- Test: `tests/aeon-core.test.cjs`

**Interfaces:**
- Consumes: queue/index/album ID and tagged import items.
- Produces: a valid remaining queue/index, cleared stale playback resources, updated `lastPlayed`, and artist-aware smart grouping.

- [ ] **Step 1: Add failing queue edge-case tests**

```js
test("deleting the current album selects no stale queue item", () => {
  const result = core.scrubQueueForAlbum(queue, 1, "deleted");
  assert.equal(result.removedCurrent, true);
  assert.deepEqual(result.queue, survivingItems);
  assert.equal(result.qIndex, 1);
});
```

- [ ] **Step 2: Verify RED**

Run: `node --test tests/aeon-core.test.cjs --test-name-pattern='queue|album'`

Expected: FAIL because deletion currently leaves queue and persisted resume entries intact.

- [ ] **Step 3: Use the helper in destructive album paths**

```js
const scrubbed = AeonCore.scrubQueueForAlbum(state.queue, state.qIndex, albumId);
state.queue = scrubbed.queue;
state.qIndex = scrubbed.qIndex;
await persistLastPlayedOrClear();
```

If the deleted album owns the current audio, pause, remove `audio.src`, revoke `curURL`, clear Media Session metadata, hide the player, and revoke its artwork URL.

- [ ] **Step 4: Verify GREEN**

Run: `npm test && npm run check`

Expected: queue-index, current-item, stale-resource, and artist-aware grouping tests pass.

---

### Task 5: Explicit metadata privacy boundary

**Files:**
- Modify: `app/index.html`
- Modify: `README.md`
- Test: `tests/aeon-core.test.cjs`

**Interfaces:**
- Consumes: explicit toggle/manual action and URL.
- Produces: data-only JSON via CORS `fetch` or Capacitor HTTP; no third-party script execution.

- [ ] **Step 1: Add a failing shipped-artifact security test**

```js
test("the shipped app contains no JSONP script injection", () => {
  assert.doesNotMatch(html, /createElement\(["']script["']\)|output=jsonp|callback=/);
});
```

- [ ] **Step 2: Verify RED**

Run: `node --test tests/aeon-core.test.cjs --test-name-pattern='JSONP|metadata'`

Expected: FAIL on the current `jsonp()` implementation.

- [ ] **Step 3: Replace JSONP and gate automatic enrichment**

```js
async function fetchJSON(url) {
  if (NATIVE && Capacitor.Plugins.CapacitorHttp) return (await Capacitor.Plugins.CapacitorHttp.get({ url })).data;
  const response = await fetch(url, { credentials: "omit", referrerPolicy: "no-referrer" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
```

Default `metadataLookups` to `false`; call `enrichAlbums(newAlbums)` only when enabled. The settings copy must state exactly what title/artist data leaves the device. Manual lookup, artwork repair, and recommendation scans remain explicit actions.

- [ ] **Step 4: Verify GREEN**

Run: `npm test && npm run check`

Expected: no JSONP execution patterns remain and the metadata default/gating checks pass.

---

### Task 6: Dependency and continuous security checks

**Files:**
- Modify: `package.json`
- Modify: `package-lock.json`
- Create: `.github/workflows/verify.yml`
- Create: `scripts/patch-capacitor-tar.cjs`
- Create: `tests/capacitor-compat.test.cjs`
- Create: `ios/App/Podfile.lock`
- Create: `ios/App/App.xcworkspace/contents.xcworkspacedata`

**Interfaces:**
- Consumes: Capacitor 6 dependencies.
- Produces: patched transitive `tar` and `brace-expansion`, reproducible install, regression/syntax checks, and high-severity audit enforcement.

- [ ] **Step 1: Capture the vulnerable baseline**

Run: `npm audit --audit-level=high`

Expected: FAIL with vulnerable `tar@6.2.1` and `brace-expansion@2.1.2` under Capacitor CLI.

- [ ] **Step 2: Apply narrow transitive overrides and regenerate the lockfile**

```json
"overrides": {
  "tar": "7.5.22",
  "brace-expansion": "2.1.4"
}
```

Because Capacitor 6's compiled CommonJS import expects `tar.default.extract`, add an idempotent `postinstall` patch that applies patched tar 7's direct `tar.extract` export—the same import shape used upstream by Capacitor 8. Cover the source transform with `tests/capacitor-compat.test.cjs`.

Run: `npm install && npx cap sync ios`

- [ ] **Step 3: Add CI enforcement**

```yaml
- run: npm ci
- run: npm test
- run: npm run check
- run: npm audit --audit-level=high
```

- [ ] **Step 4: Run full verification**

Run: `npm ci && npm test && npm run check && npm audit --audit-level=high && npx cap sync ios`

Expected: exit 0 for install, tests, syntax, audit, and Capacitor iOS sync.

---

### Task 7: Final review and direct-default publish

**Files:**
- Review: every changed path from `git status --short`

**Interfaces:**
- Consumes: verified working tree.
- Produces: one intentional commit pushed to `origin/claude/music-collection-gateway-e5ln7f`.

- [ ] **Step 1: Review scope and diff**

Run: `git status -sb && git diff --check && git diff --stat && git diff`

Expected: only hardening, tests, workflow, dependency lock, README, and this plan are changed; no whitespace errors.

- [ ] **Step 2: Re-run fresh verification**

Run: `npm ci && npm test && npm run check && npm audit --audit-level=high && npx cap sync ios`

Expected: all commands exit 0 with zero test failures and zero high/critical audit findings.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/verify.yml README.md app/index.html app/sw.js docs/superpowers/plans/2026-08-10-aeon-hardening.md package.json package-lock.json scripts/check-syntax.cjs scripts/patch-capacitor-tar.cjs tests/aeon-core.test.cjs tests/capacitor-compat.test.cjs ios/App/Podfile.lock ios/App/App.xcworkspace/contents.xcworkspacedata
git commit -m "Harden backups, restores, and metadata privacy"
git push origin claude/music-collection-gateway-e5ln7f
```

- [ ] **Step 4: Confirm remote state**

Run: `git status -sb && git rev-parse HEAD && git ls-remote origin refs/heads/claude/music-collection-gateway-e5ln7f`

Expected: clean tracking branch and matching local/remote commit IDs.
