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

function item(name, meta = {}) {
  return { file: { name }, meta };
}
const names = (items) => core().sortAlbumItems(items).map((i) => i.file.name);

test("tagged track numbers order a record before anything else does", () => {
  const items = [
    item("zebra.mp3", { track: 2 }),
    item("apple.mp3", { track: 10 }),
    item("mango.mp3", { track: 1 }),
  ];
  assert.deepEqual(names(items), ["mango.mp3", "zebra.mp3", "apple.mp3"]);
});

test("a double album keeps its discs apart instead of interleaving them", () => {
  const items = [
    item("d2t1.flac", { disc: 2, track: 1 }),
    item("d1t2.flac", { disc: 1, track: 2 }),
    item("d2t2.flac", { disc: 2, track: 2 }),
    item("d1t1.flac", { disc: 1, track: 1 }),
  ];
  assert.deepEqual(names(items), ["d1t1.flac", "d1t2.flac", "d2t1.flac", "d2t2.flac"]);
});

test("untagged files are ordered by the numbers their names carry, not alphabetically", () => {
  const items = [
    item("10 Zebra.mp3"),
    item("02 Apple.mp3"),
    item("1 Mango.mp3"),
    item("09 Quince.mp3"),
  ];
  assert.deepEqual(names(items), ["1 Mango.mp3", "02 Apple.mp3", "09 Quince.mp3", "10 Zebra.mp3"]);
});

test("names read numbers in every shape a collection uses", () => {
  const n = core().trackNumbersFromName;
  assert.deepEqual(n("03 - Title.mp3"), { disc: 0, track: 3 });
  assert.deepEqual(n("1-04 Title.flac"), { disc: 1, track: 4 });
  assert.deepEqual(n("(7) Title.m4a"), { disc: 0, track: 7 });
  assert.deepEqual(n("B3 Title.wav"), { disc: 2, track: 3 });
  assert.deepEqual(n("Title.mp3"), { disc: 0, track: 0 });
  assert.deepEqual(n("1979.mp3"), { disc: 0, track: 0 });
});

test("a record that numbers nothing falls back to the order its folder shows", () => {
  const items = [item("Intro.mp3"), item("Anthem.mp3"), item("Coda.mp3")];
  assert.deepEqual(names(items), ["Anthem.mp3", "Coda.mp3", "Intro.mp3"]);
});

test("a numbered file always precedes an unnumbered one", () => {
  const items = [item("Hidden Track.mp3"), item("02 Second.mp3"), item("01 First.mp3")];
  assert.deepEqual(names(items), ["01 First.mp3", "02 Second.mp3", "Hidden Track.mp3"]);
});

test("numbers inside a name compare as numbers", () => {
  const c = core().naturalCompare;
  assert.ok(c("Part 2", "Part 10") < 0);
  assert.ok(c("Part 10", "Part 2") > 0);
  assert.equal(c("Same", "same"), 0);
});

test('queue move preserves the exact playing occurrence among duplicates',()=>{
  const duplicate={albumId:'a',trackId:'same'};
  const queue=[duplicate,{albumId:'a',trackId:'next'},duplicate];
  const out=core().moveQueue(queue,2,0,2);
  assert.equal(out.qIndex,1);
  assert.deepEqual(out.queue,[queue[1],queue[2],queue[0]]);
  assert.equal(queue[1].trackId,'next');
});
test('moving the playing item preserves playback identity',()=>{
  const q=[{trackId:'a'},{trackId:'b'},{trackId:'c'}];
  const out=core().moveQueue(q,1,1,0);
  assert.equal(out.qIndex,0);assert.equal(out.queue[0],q[1]);
});
test('invalid queue moves leave state alone',()=>{
  const q=[{trackId:'a'}];
  assert.deepEqual(core().moveQueue(q,0,-1,0),{queue:q,qIndex:0});
  assert.deepEqual(core().moveQueue(q,0,0,99),{queue:q,qIndex:0});
});
