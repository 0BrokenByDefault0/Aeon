const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync("app/index.html", "utf8");
let loadedCore;

function core() {
  if (loadedCore) return loadedCore;
  const match = html.match(/\/\* AEON_CORE_START \*\/([\s\S]*?)\/\* AEON_CORE_END \*\//);
  assert.ok(match, "app/index.html must expose its deterministic production core");
  loadedCore = vm.runInThisContext(`(() => {${match[1]}\nreturn AeonCore;})()`, {
    filename: "app/index.html#AeonCore",
  });
  return loadedCore;
}

function tagged(album, artist, folder = "") {
  return { meta: { album, artist }, folder };
}

function validCatalog() {
  return {
    v: 2,
    exported: 1,
    skySeed: 7,
    albums: [{
      id: "album-1",
      seq: 1,
      title: "Record",
      artist: "Artist",
      year: "2026",
      genre: "Electronic",
      artFile: null,
      tracks: [{
        id: "track-1",
        idx: 1,
        title: "Track",
        artist: "Artist",
        file: "audio/track-1.flac",
        name: "01 Track.flac",
        type: "audio/flac",
      }],
    }],
    playlists: [],
    log: [],
    plays: {},
  };
}

test("maps supported audio and image extensions to their real MIME types", () => {
  assert.equal(core().mimeForFilename("song.mp3"), "audio/mpeg");
  assert.equal(core().mimeForFilename("song.m4a"), "audio/mp4");
  assert.equal(core().mimeForFilename("song.aac"), "audio/aac");
  assert.equal(core().mimeForFilename("song.flac"), "audio/flac");
  assert.equal(core().mimeForFilename("song.wav"), "audio/wav");
  assert.equal(core().mimeForFilename("song.ogg"), "audio/ogg");
  assert.equal(core().mimeForFilename("song.opus"), "audio/opus");
  assert.equal(core().mimeForFilename("cover.png"), "image/png");
});

test("derives an extension from MIME when a restored blob has no filename", () => {
  assert.equal(core().extensionForBlob({ name: "", type: "audio/flac" }, ".mp3"), ".flac");
  assert.equal(core().extensionForBlob({ name: "", type: "audio/mp4" }, ".mp3"), ".m4a");
});

test("merges album-title variants only when their artists match", () => {
  const groups = core().groupItems([
    tagged("Night Drive", "Artist One"),
    tagged("Night Drive (Deluxe Edition)", "Artist One"),
    tagged("Night Drive", "Artist Two"),
  ], "smart");
  assert.equal(groups.length, 2);
  assert.deepEqual(groups.map(group => group.length).sort(), [1, 2]);
});

test("keeps substring album names by different artists separate", () => {
  const groups = core().groupItems([
    tagged("Live", "Artist One"),
    tagged("Live at Wembley", "Artist Two"),
  ], "smart");
  assert.equal(groups.length, 2);
});

test("rejects future backup schemas", () => {
  assert.throws(
    () => core().validateBackupCatalog({ v: 99, albums: [] }, new Set()),
    /version/i,
  );
});

test("rejects duplicate track IDs and unsafe archive paths", () => {
  const duplicate = validCatalog();
  duplicate.albums[0].tracks.push({ ...duplicate.albums[0].tracks[0] });
  assert.throws(
    () => core().validateBackupCatalog(duplicate, new Set(["audio/track-1.flac"])),
    /duplicate track/i,
  );

  const unsafe = validCatalog();
  unsafe.albums[0].tracks[0].file = "../track.flac";
  assert.throws(
    () => core().validateBackupCatalog(unsafe, new Set(["../track.flac"])),
    /unsafe/i,
  );
});

test("rejects a backup with missing audio before restore", () => {
  assert.throws(
    () => core().validateBackupCatalog(validCatalog(), new Set(["isolation-backup.json"])),
    /missing audio/i,
  );
});

test("rejects catalog tracks with no archived audio path", () => {
  const catalog = validCatalog();
  catalog.albums[0].tracks[0].file = null;
  assert.throws(
    () => core().validateBackupCatalog(catalog, new Set()),
    /missing audio/i,
  );
});

test("rejects duplicate playlists and playlist items whose audio is absent", () => {
  const duplicate = validCatalog();
  duplicate.playlists = [
    { id: "playlist", name: "One", items: [] },
    { id: "playlist", name: "Two", items: [] },
  ];
  assert.throws(
    () => core().validateBackupCatalog(duplicate, new Set(["audio/track-1.flac"])),
    /duplicate playlist/i,
  );

  const dangling = validCatalog();
  dangling.playlists = [{
    id: "playlist",
    name: "One",
    items: [{ albumId: "album-1", trackId: "missing" }],
  }];
  assert.throws(
    () => core().validateBackupCatalog(dangling, new Set(["audio/track-1.flac"])),
    /playlist.*missing audio/i,
  );
});

test("accepts valid version-one and version-two backup catalogs", () => {
  const v2 = validCatalog();
  const names = new Set(["audio/track-1.flac"]);
  assert.equal(core().validateBackupCatalog(v2, names).v, 2);
  const v1 = { ...v2, v: 1 };
  assert.equal(core().validateBackupCatalog(v1, names).v, 1);
});

test("drops legacy daily-event data while normalizing a backup", () => {
  const catalog = validCatalog();
  catalog.transits = {
    witnessed: 3,
    today: { kind: "comet", key: "2026-08-11" },
    relics: [{ kind: "shower", d: "2026-08-10" }],
  };
  const normalized = core().validateBackupCatalog(
    catalog,
    new Set(["audio/track-1.flac"]),
  );
  assert.equal(Object.hasOwn(normalized, "transits"), false);
});

test("merges restored log entries without duplicating existing events", () => {
  const event = { t: 1, g: "✦", cls: "g-gold", text: "first" };
  const later = { t: 2, g: "✦", cls: "g-teal", text: "second" };
  assert.deepEqual(
    core().mergeLogEntries([event], [event, later]),
    [event, later],
  );
});

test("scrubs a deleted current album from the queue and clamps the index", () => {
  const queue = [
    { albumId: "keep-1", trackId: "a" },
    { albumId: "deleted", trackId: "b" },
    { albumId: "keep-2", trackId: "c" },
  ];
  const result = core().scrubQueueForAlbum(queue, 1, "deleted");
  assert.equal(result.removedCurrent, true);
  assert.deepEqual(result.queue, [queue[0], queue[2]]);
  assert.equal(result.qIndex, 1);
});

test("scrubbing an earlier queued album preserves the current track", () => {
  const queue = [
    { albumId: "deleted", trackId: "a" },
    { albumId: "current", trackId: "b" },
    { albumId: "keep", trackId: "c" },
  ];
  const result = core().scrubQueueForAlbum(queue, 1, "deleted");
  assert.equal(result.removedCurrent, false);
  assert.equal(result.qIndex, 0);
  assert.deepEqual(result.queue[0], queue[1]);
});

test("automatic metadata requests require explicit opt-in", () => {
  assert.equal(core().shouldAutoEnrich({}, [{ id: "album" }]), false);
  assert.equal(core().shouldAutoEnrich({ metadataLookups: false }, [{ id: "album" }]), false);
  assert.equal(core().shouldAutoEnrich({ metadataLookups: true }, [{ id: "album" }]), true);
});

test("propagates failed or cancelled backup saves", async () => {
  assert.equal(await core().saveBackup(() => Promise.resolve(false), new Blob(["x"]), "x.zip"), false);
  assert.equal(await core().saveBackup(() => Promise.resolve(true), new Blob(["x"]), "x.zip"), true);
});

test("writes and reads a stored ZIP without materializing whole source blobs", async () => {
  const bytes = Uint8Array.from([1, 2, 3, 4]);
  const source = new Blob([bytes], { type: "audio/flac" });
  source.arrayBuffer = () => { throw new Error("whole source blob copied"); };
  const zip = await core().zipWrite([{ name: "audio/track.flac", blob: source }]);
  const entries = await core().unzip(zip);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].name, "audio/track.flac");
  assert.deepEqual(new Uint8Array(await entries[0].blob.arrayBuffer()), bytes);
});

test("the shipped app contains no executable JSONP path", () => {
  assert.doesNotMatch(html, /createElement\(["']script["']\)|output=jsonp|callback=/i);
});
