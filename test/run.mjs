/* ISOLATION regression suite.
 *
 *   node test/run.mjs
 *
 * Drives the real app in a real browser against the fixtures in test/.
 * Everything asserted here is something that has actually broken at least
 * once: artwork silently corrupted by ID3 frame flags, albums torn in half
 * by ragged tags, a day's transit drifting because play counts moved under
 * it, the shell serving a host's 404 page instead of the cached app.
 */
import { chromium } from "playwright";
import http from "http";
import fs from "fs";
import path from "path";
import zlib from "zlib";
import { fileURLToPath } from "url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.join(HERE, "..", "app");
const PORT = 8917;

let mode = "live";
/* A pretend Documents folder, served with real byte-range support, so the
   adoption path can be driven end to end: the app walks it, reads tags a
   slice at a time over HTTP exactly as it does through the Capacitor
   bridge, and adopts what it finds. */
const disk = new Map();                        // "Music/Artist/Album/01.mp3" -> Buffer
const server = http.createServer((req, res) => {
  if (req.url.startsWith("/__file/DOCUMENTS/")) {
    const key = decodeURIComponent(req.url.slice("/__file/DOCUMENTS/".length));
    const buf = disk.get(key);
    if (!buf) { res.statusCode = 404; return res.end(); }
    const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || "");
    if (range) {
      const a = Number(range[1]);
      const b = range[2] === "" ? buf.length - 1 : Math.min(Number(range[2]), buf.length - 1);
      if (a >= buf.length) { res.statusCode = 416; return res.end(); }
      res.statusCode = 206;
      res.setHeader("content-range", `bytes ${a}-${b}/${buf.length}`);
      return res.end(buf.subarray(a, b + 1));
    }
    return res.end(buf);
  }
  if (mode === "gone") {                       // a host that outlived its site
    res.statusCode = 404;
    res.setHeader("content-type", "text/html");
    return res.end("<html><body><h1>Not Found</h1></body></html>");
  }
  const file = path.join(APP, req.url === "/" ? "index.html" : req.url.split("?")[0]);
  try {
    res.setHeader("content-type",
      file.endsWith(".html") ? "text/html" :
      file.endsWith(".js") ? "text/javascript" :
      file.endsWith(".webmanifest") ? "application/manifest+json" : "application/octet-stream");
    res.end(fs.readFileSync(file));
  } catch { res.statusCode = 404; res.end(); }
});

let passed = 0, failed = 0;
const ok = (name, cond, detail) => {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}${detail !== undefined ? `  →  ${JSON.stringify(detail)}` : ""}`); }
};
const fixture = f => path.join(HERE, f);

/* Just enough zip to reuse the audio fixtures as loose files on the
   pretend disk — central directory, then each local header. */
function readZip(file) {
  const b = fs.readFileSync(file);
  let eocd = b.length - 22;
  while (eocd >= 0 && b.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error("not a zip: " + file);
  const count = b.readUInt16LE(eocd + 10);
  let p = b.readUInt32LE(eocd + 16);
  const out = [];
  for (let i = 0; i < count; i++) {
    const method = b.readUInt16LE(p + 10);
    const csize = b.readUInt32LE(p + 20);
    const nlen = b.readUInt16LE(p + 28);
    const elen = b.readUInt16LE(p + 30);
    const clen = b.readUInt16LE(p + 32);
    const name = b.toString("utf8", p + 46, p + 46 + nlen);
    const lho = b.readUInt32LE(p + 42);
    const lnlen = b.readUInt16LE(lho + 26), lelen = b.readUInt16LE(lho + 28);
    const start = lho + 30 + lnlen + lelen;
    const raw = b.subarray(start, start + csize);
    out.push({ name, data: method === 0 ? raw : zlib.inflateRawSync(raw) });
    p += 46 + nlen + elen + clen;
  }
  return out;
}

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium",
});

async function session() {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  page.on("dialog", d => d.accept());
  // the suite must never depend on the network
  await page.route("**://itunes.apple.com/**", r => r.abort());
  await page.route("**://musicbrainz.org/**", r => r.abort());
  await page.route("**://coverartarchive.org/**", r => r.abort());
  await page.goto(`http://localhost:${PORT}/`);
  await page.waitForTimeout(900);
  return { ctx, page, errors };
}

server.listen(PORT);

/* ── artwork survives every ID3 layout, and corrupt art is dropped ── */
{
  console.log("\nartwork");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("edge3.zip"));
  await page.waitForTimeout(4000);
  const art = await page.evaluate(async () => {
    const out = {};
    for (const a of state.albums) {
      let decodes = false;
      if (a.art) {
        const url = URL.createObjectURL(a.art);
        await new Promise(res => {
          const im = new Image();
          im.onload = () => { decodes = true; res(); };
          im.onerror = () => res();
          im.src = url;
        });
        URL.revokeObjectURL(url);
      }
      out[a.title] = { hasArt: !!a.art, decodes };
    }
    return out;
  });
  for (const name of ["DLI", "UNSYNCTHREE", "FRAMEUN", "GROUPED", "PLAINTHREE"])
    ok(`${name} keeps decodable art`, art[name] && art[name].decodes, art[name]);
  ok("corrupt art is dropped, not stored broken", art.BROKEN && !art.BROKEN.hasArt, art.BROKEN);
  ok("no broken images in the grid", await page.evaluate(async () => {
    switchTab("library");
    await new Promise(r => setTimeout(r, 400));
    return [...document.querySelectorAll("#libGrid img.art")].every(i => i.complete && i.naturalWidth > 0);
  }));
  await ctx.close();
}

/* ── one upload is one album; folders still divide ── */
{
  console.log("\nimport grouping");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("split.zip"));
  await page.waitForTimeout(3500);
  ok("ragged album tags do not split a record",
    await page.evaluate(() => state.albums.length) === 1,
    await page.evaluate(() => state.albums.map(a => a.title)));
  ok("tracks are renumbered 1..n",
    (await page.evaluate(() => (state.tracks.get(state.albums[0].id) || [])
      .slice().sort((a, b) => a.idx - b.idx).map(t => t.idx))).join() === "1,2,3,4,5");
  await page.setInputFiles("#fileInput", fixture("library.zip"));
  await page.waitForTimeout(9000);
  ok("a multi-folder archive still splits per folder",
    await page.evaluate(() => state.albums.length) === 21,
    await page.evaluate(() => state.albums.length));
  await page.setInputFiles("#fileInput", fixture("library.zip"));
  await page.waitForTimeout(7000);
  ok("re-importing the same music adds nothing",
    await page.evaluate(() => state.albums.length) === 21);
  await ctx.close();
}

/* ── merging and reordering keep every reference intact ── */
{
  console.log("\nlibrary editing");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("split.zip"));
  await page.waitForTimeout(3500);
  await page.setInputFiles("#fileInput", fixture("single.zip"));
  await page.waitForTimeout(3000);
  const res = await page.evaluate(async () => {
    const src = state.albums.find(a => /vampire/i.test(a.title));
    const dst = state.albums.find(a => a.id !== src.id);
    const t = (state.tracks.get(src.id) || [])[0];
    const pl = { id: uid(), name: "probe", items: [{ albumId: src.id, trackId: t.id }] };
    state.playlists.push(pl); await dbPut("playlists", pl);
    await mergeAlbums(src.id, dst.id);
    const item = state.playlists.find(p => p.id === pl.id).items[0];
    return {
      albums: state.albums.length,
      tracks: (state.tracks.get(dst.id) || []).length,
      order: (state.tracks.get(dst.id) || []).slice().sort((a, b) => a.idx - b.idx).map(x => x.idx),
      playlistResolves: !!trackById(item.albumId, item.trackId),
    };
  });
  ok("merge folds the single away", res.albums === 1, res);
  ok("merged tracks renumber cleanly", res.order.join() === "1,2,3,4,5,6", res.order);
  ok("playlists follow the moved tracks", res.playlistResolves);
  await ctx.close();
}

/* ── a play must be earned, since the transits read these counts ── */
{
  console.log("\nlistening history");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("single.zip"));
  await page.waitForTimeout(3000);
  const counts = await page.evaluate(async () => {
    const a = state.albums[0], t = (state.tracks.get(a.id) || [])[0];
    playCounts = {};
    playQueue([{ albumId: a.id, trackId: t.id }], 0);
    await new Promise(r => setTimeout(r, 800));
    const onSelect = playCounts[t.id] || 0;
    audio.currentTime = 999; creditListening();
    return { onSelect, afterListening: playCounts[t.id] || 0 };
  });
  ok("selecting a track is not a play", counts.onSelect === 0, counts);
  ok("listening is a play", counts.afterListening === 1, counts);
  await ctx.close();
}

/* ── the native path ──
 * This suite used to run only as a browser, where storeAudio returns a blob
 * and never touches the filesystem helpers. A missing helper in the device
 * branch therefore sailed through every check and shipped in an IPA that
 * imported 28 files and stored none of them. The Capacitor bridge is now
 * stubbed so the device path is exercised for real.
 */
{
  console.log("\nnative storage path");
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await ctx.addInitScript(() => {
    const disk = {};
    window.__disk = disk;
    window.Capacitor = {
      isNativePlatform: () => true,
      convertFileSrc: u => u.replace("file://", "http://localhost:8917/__file/"),
      Plugins: {
        Filesystem: {
          async writeFile({ path, data }) { disk[path] = data === "" ? [] : [data]; return {}; },
          async appendFile({ path, data }) { (disk[path] = disk[path] || []).push(data); return {}; },
          async getUri({ path }) {
            if (!(path in disk)) throw new Error("File does not exist");
            return { uri: "file:///DOCUMENTS/" + path };
          },
          async deleteFile({ path }) { delete disk[path]; return {}; },
        },
        Share: { async share() { return {}; } },
      },
    };
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  page.on("dialog", d => d.accept());
  await page.route("**://itunes.apple.com/**", r => r.abort());
  await page.route("**://musicbrainz.org/**", r => r.abort());
  await page.goto(`http://localhost:${PORT}/`);
  await page.waitForTimeout(900);
  ok("the app knows it is native", await page.evaluate(() => NATIVE === true));
  await page.setInputFiles("#fileInput", fixture("split.zip"));
  await page.waitForTimeout(5000);
  const res = await page.evaluate(() => {
    const a = state.albums[0];
    const tracks = a ? (state.tracks.get(a.id) || []) : [];
    return {
      albums: state.albums.length,
      tracks: tracks.length,
      withPath: tracks.filter(t => t.path).length,
      withBlob: tracks.filter(t => t.blob).length,
      bytes: tracks.every(t => t.bytes > 0),
      filesOnDisk: Object.keys(window.__disk).length,
      sample: tracks[0] && tracks[0].path,
    };
  });
  ok("the album survives the import", res.albums === 1, res);
  ok("every track was written to disk", res.tracks > 0 && res.withPath === res.tracks, res);
  ok("no audio blob is kept in memory", res.withBlob === 0, res);
  ok("byte sizes are recorded", res.bytes, res);
  ok("files actually landed on the filesystem", res.filesOnDisk === res.tracks, res);
  ok("paths keep the real extension", /\.mp3$/.test(res.sample || ""), res.sample);
  ok("playback resolves a file URL", await page.evaluate(async () => {
    const a = state.albums[0], t = (state.tracks.get(a.id) || [])[0];
    const url = await trackURL(t);
    return typeof url === "string" && url.includes("/__file/");
  }));
  ok("the storage card reports the library, not a quota", await page.evaluate(async () => {
    switchTab("settings");
    await updateStorage();
    return /of music on this device/.test(document.querySelector("#storText").textContent);
  }));
  ok("deleting an album reclaims its files", await page.evaluate(async () => {
    const before = Object.keys(window.__disk).length;
    const a = state.albums[0];
    sheetAlbumId = a.id;
    await new Promise(r => setTimeout(r, 50));
    document.querySelector("#albDelete").click();
    await new Promise(r => setTimeout(r, 1200));
    return Object.keys(window.__disk).length < before;
  }));
  ok("no errors on the device path", errors.length === 0, errors);
  await ctx.close();
}

/* ── backup, wipe, restore ── */
{
  console.log("\nbackup and restore");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("library.zip"));
  await page.waitForTimeout(9000);
  const out = path.join(HERE, ".backup.zip");
  const dl = page.waitForEvent("download");
  await page.evaluate(() => switchTab("settings"));
  await page.click("#btnExportAll");
  await (await dl).saveAs(out);
  ok("a backup is written", fs.existsSync(out) && fs.statSync(out).size > 1000);
  await page.click("#btnWipe"); await page.waitForTimeout(1200);
  ok("wipe empties the sky", await page.evaluate(() => state.albums.length) === 0);
  await page.setInputFiles("#fileInput", out); await page.waitForTimeout(8000);
  ok("restore brings the library back",
    await page.evaluate(() => state.albums.length) === 20,
    await page.evaluate(() => state.albums.length));
  fs.unlinkSync(out);
  await ctx.close();
}

/* ── the shell outlives its host ── */
{
  console.log("\noffline shell");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("single.zip"));
  await page.waitForTimeout(3000);
  await page.reload(); await page.waitForTimeout(1200);
  await page.reload(); await page.waitForTimeout(1500);   // service worker in control
  const version = () => page.evaluate(() =>
    document.querySelector("#panel-settings > div[style]").textContent.trim());
  const live = await version();
  mode = "gone";
  await page.reload(); await page.waitForTimeout(2500);
  ok("a deleted site still opens the app", await version() === live);
  ok("the library is still there", await page.evaluate(() => state.albums.length) === 1);
  mode = "live";
  await ctx.setOffline(true);
  await page.reload(); await page.waitForTimeout(2500);
  ok("so does a total outage", await version() === live);
  await ctx.setOffline(false);
  await ctx.close();
}

/* ── a whole library dropped into the Music folder, adopted in place ── */
{
  console.log("\nadopting a library in place");
  /* Lay out a master folder the way a collector's drive actually looks:
     artist folders, album folders inside them, and two different albums
     sharing the leaf name "Live" — the case that fuses two records into
     one if folders are told apart by their last name only. */
  disk.clear();
  const put = (p, buf) => disk.set(p, buf);
  const zip = readZip(fixture("library.zip"));
  const grab = n => zip.find(e => e.name === n).data;
  put("Music/Ken Carson/A Great Chaos/01 one.mp3", grab("Ken Carson - A Great Chaos/01 Track 1.mp3"));
  put("Music/Ken Carson/A Great Chaos/02 two.mp3", grab("Ken Carson - A Great Chaos/02 Track 2.mp3"));
  put("Music/Ken Carson/Live/01 one.mp3", grab("Ken Carson - X/01 Track 1.mp3"));
  put("Music/Playboi Carti/Live/01 one.mp3", grab("Playboi Carti - Die Lit/01 Track 1.mp3"));
  put("Music/Playboi Carti/Whole Lotta Red/01 one.mp3", grab("Playboi Carti - Whole Lotta Red/01 Track 1.mp3"));
  put("Music/Playboi Carti/Whole Lotta Red/02 two.mp3", grab("Playboi Carti - Whole Lotta Red/02 Track 2.mp3"));
  put("Music/.hidden/ignored.mp3", grab("Burial - Untrue/01 Track 1.mp3"));  // dotfolders are not albums
  put("Music/Ken Carson/A Great Chaos/notes.txt", Buffer.from("not audio"));

  const tree = {};
  for (const key of disk.keys()) {
    const parts = key.split("/");
    for (let i = 0; i < parts.length; i++) {
      const dir = parts.slice(0, i).join("/");
      (tree[dir] = tree[dir] || new Map()).set(parts[i],
        i === parts.length - 1 ? { type: "file", size: disk.get(key).length } : { type: "directory", size: 0 });
    }
  }
  const listing = {};
  for (const [dir, entries] of Object.entries(tree))
    listing[dir] = [...entries].map(([name, v]) => ({ name, type: v.type, size: v.size, uri: "file:///DOCUMENTS/" + (dir ? dir + "/" : "") + name }));

  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await ctx.addInitScript(l => {
    const written = {};
    window.__written = written;
    window.Capacitor = {
      isNativePlatform: () => true,
      convertFileSrc: u => u.replace("file://", "http://localhost:8917/__file"),
      Plugins: {
        Filesystem: {
          async readdir({ path }) {
            if (!(path in l)) throw new Error("no such directory");
            return { files: l[path] };
          },
          async getUri({ path }) { return { uri: "file:///DOCUMENTS/" + path }; },
          async writeFile({ path, data }) { written[path] = data === "" ? [] : [data]; return {}; },
          async appendFile({ path, data }) { (written[path] = written[path] || []).push(data); return {}; },
          async deleteFile({ path }) { delete written[path]; return {}; },
        },
        Share: { async share() { return {}; } },
      },
    };
  }, listing);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.route("**://itunes.apple.com/**", r => r.abort());
  await page.route("**://musicbrainz.org/**", r => r.abort());
  await page.goto(`http://localhost:${PORT}/`);
  await page.waitForTimeout(900);

  ok("the adopt button is offered on device", await page.evaluate(() =>
    document.querySelector("#btnAdopt").style.display !== "none"));

  await page.evaluate(() => adoptLibrary());
  await page.waitForTimeout(9000);
  const res = await page.evaluate(() => {
    const all = state.albums.map(a => ({
      title: a.title, artist: a.artist,
      tracks: (state.tracks.get(a.id) || []).map(t => ({ path: t.path, adopted: !!t.adopted, blob: !!t.blob, bytes: t.bytes })),
    }));
    return { albums: all.length, all, copied: Object.keys(window.__written).length };
  });
  const dirOf = p => p.split("/").slice(0, -1).join("/");
  ok("every folder holding audio became one album", res.albums === 4, res.all.map(a => a.title));
  ok("no album straddles two folders",
    res.all.every(a => new Set(a.tracks.map(t => dirOf(t.path))).size === 1), res.all);
  ok("two folders sharing a name under different artists stay apart",
    res.all.filter(a => a.tracks.some(t => t.path.includes("/Live/"))).length === 2, res.all);
  ok("tracks point at the files where they already were",
    res.all.every(a => a.tracks.every(t => t.path && t.path.startsWith("Music/") && t.adopted)), res.all);
  ok("nothing was copied", res.copied === 0, res.copied);
  ok("no audio is held in memory", res.all.every(a => a.tracks.every(t => !t.blob)), res.all);
  ok("byte sizes came from the filesystem", res.all.every(a => a.tracks.every(t => t.bytes > 0)), res.all);
  ok("a dotfolder is not a collection", res.all.every(a => !a.tracks.some(t => t.path.includes("/.hidden/"))), res.all);

  // running it twice must not double the library
  await page.evaluate(() => adoptLibrary());
  await page.waitForTimeout(5000);
  ok("adopting again finds nothing new", await page.evaluate(() => state.albums.length) === 4);

  // removing an adopted album must never delete the collector's file
  ok("removing an adopted album leaves the file alone", await page.evaluate(async () => {
    const a = state.albums[0];
    const t = (state.tracks.get(a.id) || [])[0];
    await dropAudio(t);
    const res = await fetch("http://localhost:8917/__file/DOCUMENTS/" + t.path);
    return res.ok;
  }));

  /* the grouping rule itself, stated plainly: the leaf name is a label,
     the path is the identity — and items that only ever carried a leaf
     name still group the way they always did */
  const grouping = await page.evaluate(() => {
    const mk = (folder, folderKey) => ({ folder, folderKey, meta: {} });
    return {
      byPath: AeonCore.groupItems([
        mk("Live", "Music/A/Live"), mk("Live", "Music/B/Live"),
      ], "folder").length,
      byLeaf: AeonCore.groupItems([mk("Live"), mk("Live")], "folder").length,
    };
  });
  ok("same folder name, different paths, different albums", grouping.byPath === 2, grouping);
  ok("a bare folder name still groups as one", grouping.byLeaf === 1, grouping);

  ok("no errors while adopting", errors.length === 0, errors.slice(0, 3));
  await ctx.close();
  disk.clear();
}

/* ── one unplayable file must not take the queue down with it ── */
{
  console.log("\nbad files");
  const { ctx, page } = await session();
  await page.setInputFiles("#fileInput", fixture("split.zip"));
  await page.waitForTimeout(3500);
  const res = await page.evaluate(async () => {
    const a = state.albums[0];
    const tracks = (state.tracks.get(a.id) || []).slice().sort((x, y) => x.idx - y.idx);
    playQueue(tracks.map(t => ({ albumId: a.id, trackId: t.id })), 0);
    await new Promise(r => setTimeout(r, 700));
    const before = state.qIndex;
    // a file the device cannot decode, exactly as a bad download behaves
    audio.src = "data:audio/mpeg;base64,QUJD";
    audio.load();
    await new Promise(r => setTimeout(r, 1400));
    return { before, after: state.qIndex, queue: state.queue.length };
  });
  ok("a file that will not play is skipped, not a dead end",
    res.after === res.before + 1, res);
  // …but a queue of nothing but bad files stops instead of racing to the end
  const stopped = await page.evaluate(async () => {
    for (let i = 0; i < 8; i++) {
      audio.src = "data:audio/mpeg;base64,QUJD";
      audio.load();
      await new Promise(r => setTimeout(r, 500));
    }
    return { qIndex: state.qIndex, queue: state.queue.length };
  });
  ok("a queue of bad files stops rather than racing through",
    stopped.qIndex < stopped.queue, stopped);
  await ctx.close();
}

/* ── a large collection stays cheap ── */
{
  console.log("\nscale");
  const { ctx, page } = await session();
  const N = 1200;
  await page.evaluate(n => {
    const G = ["electronic", "ambient", "post-rock", "jazz", "dubstep", "industrial"];
    for (let i = 0; i < n; i++) {
      const a = { id: "s-" + i, title: "Record " + i, artist: "Artist " + (i % 150),
        genre: G[i % 6], year: 1990 + (i % 30), seq: ++seqCounter, added: Date.now(),
        mock: true, trackCount: 9, tracks: 1 };
      state.albums.push(a);
      state.tracks.set(a.id, [{ id: a.id + "-t1", albumId: a.id, idx: 1, title: "Bellwether Hymn " + i }]);
    }
    sky.rebuild(); renderLibrary();
  }, N);
  await page.waitForTimeout(1200);

  /* the grid is built a page at a time — the whole library as one string
     was what made a big collection take seconds to show anything */
  const first = await page.evaluate(() => document.querySelectorAll("#libGrid [data-alb]").length);
  ok("the grid builds a page at a time", first > 0 && first < N, { first, N });

  // and everything is still reachable by scrolling
  const grown = await page.evaluate(async () => {
    switchTab("library");
    for (let i = 0; i < 40; i++) { fillWhileVisible(); await new Promise(r => setTimeout(r, 10)); }
    while (libShown < libRows.length) libPage();
    return document.querySelectorAll("#libGrid [data-alb]").length;
  });
  ok("scrolling reaches every album", grown === N, { grown, N });

  // one handler for the whole grid, however many cards
  ok("a card still opens its album", await page.evaluate(async () => {
    document.querySelector("#libGrid [data-alb]").click();
    await new Promise(r => setTimeout(r, 400));
    return document.querySelector("#sheetAlbum").classList.contains("open");
  }));
  await page.evaluate(() => closeSheet("sheetAlbum"));
  await page.waitForTimeout(400);

  /* Search now answers from the album's own fields first and only reads
     tracklists when it must. The point is that the answer is the same as
     the one the single-haystack version gave, so it is checked against
     that original rule directly, album by album, query by query. */
  const search = await page.evaluate(() => {
    const original = (a, q) => {
      const hay = foldSearch(a.title + " " + a.artist + " " + (a.genre || "") + " " + (a.year || "")
        + " " + (state.tracks.get(a.id) || []).map(t => t.title).join(" "));
      return q.split(/\s+/).filter(Boolean).every(tok => hay.includes(tok));
    };
    const queries = ["record 7", "artist 12", "bellwether hymn 42", "zzzznotathing",
      "artist 12 bellwether", "", "  ", "RECORD 100", "hymn", "jazz 1994"];
    const out = { disagreements: 0, counts: {} };
    for (const q of queries) {
      libQuery = foldSearch(q).trim();
      let n = 0;
      for (const a of state.albums) {
        const mine = libMatches(a), theirs = original(a, libQuery);
        if (mine !== theirs) out.disagreements++;
        if (mine) n++;
      }
      out.counts[q || "(empty)"] = n;
    }
    libQuery = ""; renderLibrary();
    return out;
  });
  ok("search returns exactly what it always did", search.disagreements === 0, search);
  ok("and still finds titles, artists and track names",
    search.counts["record 7"] > 0 && search.counts["artist 12"] > 0
    && search.counts["hymn"] === N && search.counts["zzzznotathing"] === 0, search.counts);

  /* nothing is drawn for a sky nobody is looking at */
  const idle = await page.evaluate(async () => {
    const at = t => new Promise(r => setTimeout(r, t));
    switchTab("library"); await at(500);
    const a = sky.framesDrawn(); await at(700);
    const off = sky.framesDrawn() - a;
    switchTab("sky"); await at(300);
    const b = sky.framesDrawn(); await at(700);
    return { off, on: sky.framesDrawn() - b };
  });
  ok("the sky idles when it is off screen", idle.off === 0, idle);
  ok("and paints again the moment it is back", idle.on > 10, idle);

  /* a bad camera number would blank the sky for every frame after it */
  ok("the camera recovers from a bad number", await page.evaluate(async () => {
    sky.look(NaN, NaN, NaN);
    await new Promise(r => setTimeout(r, 600));
    const f = sky.frame();
    return isFinite(f.cx) && isFinite(f.cy) && isFinite(f.s) && f.s > 0;
  }));
  await ctx.close();
}

/* ── genres survive the way people actually write tags ── */
{
  console.log("\ngenre sanity");
  const { ctx, page } = await session();

  const fold = await page.evaluate(() => {
    const k = AeonCore.genreKey;
    const same = (...v) => new Set(v.map(k)).size === 1;
    return {
      spelling: same("Hip-Hop", "hip hop", "HipHop", "HIP HOP", " Hip-Hop "),
      multi: same("Hip-Hop", "Hip-Hop/Rap", "Hip-Hop; Rap", "Hip-Hop, Rap"),
      synonym: same("Hip-Hop", "Rap", "rap"),
      ampersand: same("Drum & Bass", "Drum and Bass", "drum n bass", "DnB"),
      accents: same("Bossa Nova", "Bossa Nová"),
      plural: same("Ballad", "Ballads"),
      numeric: k("(17)") === k("Rock") && k("(17)Rock") === k("Rock"),
      leadingThe: same("The Blues", "Blues"),
      blank: k("") === "" && k(null) === "" && k("   ") === "",
      // genuinely different genres must stay different
      distinct: new Set(["Rock", "Post-Rock", "Metal", "Jazz", "Ambient", "Techno"].map(k)).size === 6,
    };
  });
  for (const [name, pass] of Object.entries(fold))
    ok(`genre keys agree on ${name}`, pass === true, fold);

  /* the point of all that: one region, not six */
  const regions = await page.evaluate(() => {
    const spellings = ["Hip-Hop", "hip hop", "HipHop", "Hip-Hop/Rap", "Rap", "HIP HOP"];
    spellings.forEach((g, i) => {
      const a = { id: "g-" + i, title: "R" + i, artist: "Artist " + i, genre: g,
        year: 2000, seq: ++seqCounter, added: Date.now(), mock: true, tracks: 1 };
      state.albums.push(a); state.tracks.set(a.id, []);
    });
    sky.rebuild();
    return sky.regions().map(r => r.name);
  });
  ok("six spellings of one genre make one region", regions.length === 1, regions);
  ok("and it is labelled the way the collector writes it",
    /HIP/.test(regions[0] || ""), regions);

  /* blanks are filled from the artist's own records, then the table */
  const filled = await page.evaluate(async () => {
    state.albums.length = 0; state.tracks.clear();
    const add = (id, artist, genre) => {
      const a = { id, title: id, artist, genre, year: 2000,
        seq: ++seqCounter, added: Date.now(), mock: true, tracks: 1 };
      state.albums.push(a); state.tracks.set(a.id, []);
      return a;
    };
    add("k1", "Some Local Band", "Slowcore");
    add("k2", "Some Local Band", "Slowcore");
    const fromArtist = add("k3", "Some Local Band", "");
    // an artist the library has no other evidence about
    const fromTable = add("k4", "Boards of Canada", "");
    const untouched = add("k5", "Aphex Twin", "Field Recording");
    const unknown = add("k6", "Nobody At All Here", "");
    await fillMissingGenres();
    return {
      fromArtist: fromArtist.genre, fromArtistMark: fromArtist.genreAuto,
      fromTable: fromTable.genre, fromTableMark: fromTable.genreAuto,
      untouched: untouched.genre, untouchedMark: untouched.genreAuto,
      unknown: unknown.genre,
    };
  });
  ok("a blank inherits the artist's own genre", filled.fromArtist === "Slowcore", filled);
  ok("and is marked as inferred, not tagged", filled.fromArtistMark === "artist", filled);
  ok("an artist the library knows nothing about uses the table",
    filled.fromTable === "Electronic" && filled.fromTableMark === "table", filled);
  ok("a real tag is never overwritten", filled.untouched === "Field Recording"
    && filled.untouchedMark === undefined, filled);
  ok("an unknown artist stays honestly unknown", filled.unknown === "", filled);

  await ctx.close();
}

/* ── conjured stars fill the sky without a queue of ceremonies ── */
{
  console.log("\nmock stars");
  const { ctx, page } = await session();
  const run = await page.evaluate(async () => {
    const banners = [], flights = [];
    const realBanner = sky.banner, realCst = sky.ceremonyConstellation, realPlanet = sky.ceremonyPlanet;
    sky.banner = (...a) => { banners.push(a[0]); };
    sky.ceremonyConstellation = k => flights.push("cst:" + k);
    sky.ceremonyPlanet = p => flights.push("planet:" + p);
    const logBefore = state.log.length;
    await runMock(60, "test");
    // ceremonies are queued on timers, so give them every chance to fire
    await new Promise(r => setTimeout(r, 4000));
    const out = { banners: banners.length, flights: flights.length,
      albums: state.albums.length, logAdded: state.log.length - logBefore };
    sky.banner = realBanner; sky.ceremonyConstellation = realCst; sky.ceremonyPlanet = realPlanet;
    return out;
  });
  ok("sixty conjured stars arrive", run.albums === 60, run);
  ok("with no banners to sit through", run.banners === 0, run);
  ok("no camera flights", run.flights === 0, run);
  ok("and no ceremony spam in the log", run.logAdded === 0, run);
  await ctx.close();
}

/* ── every world a collector wakes is its own colour ── */
{
  console.log("\nworlds");
  const { ctx, page } = await session();
  const inks = await page.evaluate(() => {
    for (let i = 0; i < 250; i++) {
      const a = { id: "p-" + i, title: "R" + i, artist: "A" + (i % 30), genre: "test",
        year: 2000, seq: ++seqCounter, added: Date.now(), mock: true, tracks: 1 };
      state.albums.push(a); state.tracks.set(a.id, []);
    }
    sky.rebuild();
    const ws = sky.worlds();
    return { n: ws.length, distinct: new Set(ws.map(w => w.ink)).size,
      allHaveInk: ws.every(w => Number.isInteger(w.ink)) };
  });
  ok("twelve worlds wake for a large library", inks.n >= 12, inks);
  ok("and the first twelve are twelve different colours",
    inks.distinct >= 12 && inks.allHaveInk, inks);
  await ctx.close();
}

/* ── the handle on every sheet is real, and the figures are figures ── */
{
  console.log("\ngestures");
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.route("**://itunes.apple.com/**", r => r.abort());
  await page.route("**://musicbrainz.org/**", r => r.abort());
  await page.goto(`http://localhost:${PORT}/`);
  await page.waitForTimeout(900);

  // a synthetic finger, since these are touch gestures
  const swipe = (sel, x, y0, y1, steps = 14) => page.evaluate(async ({ sel, x, y0, y1, steps }) => {
    const el = document.querySelector(sel);
    const fire = (type, cy) => {
      const t = new Touch({ identifier: 1, target: el, clientX: x, clientY: cy });
      el.dispatchEvent(new TouchEvent(type, {
        touches: type === "touchend" ? [] : [t], targetTouches: type === "touchend" ? [] : [t],
        changedTouches: [t], bubbles: true, cancelable: true,
      }));
    };
    fire("touchstart", y0);
    for (let i = 1; i <= steps; i++) { fire("touchmove", y0 + (y1 - y0) * i / steps); await new Promise(r => setTimeout(r, 16)); }
    fire("touchend", y1);
  }, { sel, x, y0, y1, steps });
  const isOpen = id => page.evaluate(i => document.querySelector("#" + i).classList.contains("open"), id);

  await page.evaluate(() => openSheet("sheetNow"));
  await page.waitForTimeout(700);
  await swipe("#sheetNow .sheet-body", 195, 300, 780);
  await page.waitForTimeout(600);
  ok("pulling a sheet down dismisses it", await isOpen("sheetNow") === false);

  await page.evaluate(() => openSheet("sheetNow"));
  await page.waitForTimeout(700);
  await swipe("#sheetNow .sheet-body", 195, 300, 330);
  await page.waitForTimeout(600);
  ok("a short tug springs back", await isOpen("sheetNow") === true);
  ok("and leaves no transform behind", await page.evaluate(() =>
    document.querySelector("#sheetNow .sheet-body").style.transform) === "");

  /* swapping one sheet for another in a single tick must land on the new
     sheet — the history entry the old one gives back must not take it */
  await page.evaluate(() => { closeSheet("sheetNow"); openSheet("sheetGuide"); });
  await page.waitForTimeout(800);
  ok("closing one sheet and opening another keeps the new one", await isOpen("sheetGuide") === true);

  // a sheet mid-scroll must scroll, not leave
  const scrolled = await page.evaluate(() => {
    const b = document.querySelector("#sheetGuide .sheet-body");
    b.scrollTop = 10000;                 // as far as this sheet will go
    return b.scrollTop;
  });
  await swipe("#sheetGuide .sheet-body", 195, 300, 700);
  await page.waitForTimeout(600);
  ok("a scrolled sheet scrolls instead of closing",
    scrolled > 0 && await isOpen("sheetGuide") === true, { scrolled });

  /* …but the handle is never the scroller's to take: pulling it must
     close the sheet even mid-scroll, which is the guarantee that makes
     the gesture trustworthy on a device */
  await swipe("#sheetGuide .grab", 195, 120, 640);
  await page.waitForTimeout(600);
  ok("the handle closes a scrolled sheet anyway", await isOpen("sheetGuide") === false);
  await page.waitForTimeout(400);

  // a sheet whose content fits hands its whole surface to the gesture
  await page.evaluate(() => openSheet("sheetNow"));
  await page.waitForTimeout(700);
  ok("a sheet that cannot scroll is draggable everywhere", await page.evaluate(() =>
    document.querySelector("#sheetNow .sheet-body").classList.contains("fits")));
  await page.evaluate(() => closeSheet("sheetNow"));
  await page.waitForTimeout(600);

  await swipe("#playerBar", 195, 700, 620);
  await page.waitForTimeout(600);
  ok("pulling up on the bar opens the player", await isOpen("sheetNow") === true);
  await swipe("#nowArt", 195, 300, 200);
  await page.waitForTimeout(600);
  ok("pulling up on the sleeve opens up next", await isOpen("sheetQueue") === true);

  /* an artist's figure is grown, not stamped: it must be lopsided, it
     must branch once it is big enough, and a new record must extend it
     rather than rearrange the shape the collector already knows. */
  const fig = await page.evaluate(() => {
    const add = (artist, i) => {
      const a = { id: "t-" + artist + "-" + i, title: "R" + i, artist, genre: "test",
        year: 2000 + i, seq: ++seqCounter, added: Date.now(), mock: true, tracks: 1 };
      state.albums.push(a); state.tracks.set(a.id, []);
    };
    for (let i = 1; i <= 9; i++) add("Deep", i);
    for (let i = 1; i <= 3; i++) add("Shallow", i);
    // a dozen more deep artists, because branching is a chance per album
    for (let d = 0; d < 12; d++) for (let i = 1; i <= 9; i++) add("Deep" + d, i);
    sky.rebuild();
    const of = n => sky.constellations().find(c => c.name === n);
    const spread = c => {
      const d = c.stars.map(s => Math.hypot(s.x - c.cx, s.y - c.cy));
      const m = d.reduce((a, b) => a + b, 0) / d.length;
      return Math.sqrt(d.reduce((a, b) => a + (b - m) ** 2, 0) / d.length) / (m || 1);
    };
    const deep = of("Deep");
    const junctionsOf = c => {
      const deg = {};
      c.edges.forEach(([a, b]) => { deg[a] = (deg[a] || 0) + 1; deg[b] = (deg[b] || 0) + 1; });
      return Object.values(deg).filter(v => v > 2).length;
    };
    /* Whether any one figure branches is a roll of the dice — about one
       in seventeen nine-album artists never does. What must hold is that
       branching happens across a sky, so it is counted over all of them. */
    const branched = Array.from({ length: 12 }, (_, d) => of("Deep" + d))
      .filter(c => c && junctionsOf(c) >= 1).length;
    const rel = c => { const s = c.stars; return s.slice(1).map(p => [Math.round(p.x - s[0].x), Math.round(p.y - s[0].y)]); };
    const before = rel(deep);
    add("Deep", 10); sky.rebuild();
    const after = rel(of("Deep"));
    return {
      edges: deep.edges.length, stars: deep.stars.length,
      spreadDeep: spread(deep), spreadShallow: spread(of("Shallow")),
      branched,
      grew: after.length === before.length + 1,
      kept: before.every((p, i) => Math.abs(p[0] - after[i][0]) < 2 && Math.abs(p[1] - after[i][1]) < 2),
    };
  });
  /* Worlds are the largest things in the sky, so where they are put is
     the whole of whether they belong there. A world must never sit on a
     genre's region, in the band above it where its name is set, or on
     another world — the failure that made them look dropped in. */
  const worlds = await page.evaluate(() => {
    for (let i = 0; i < 90; i++) {
      const a = { id: "w-" + i, title: "R" + i, artist: "A" + (i % 11), genre: ["a", "b", "c", "d"][i % 4],
        year: 2000, seq: ++seqCounter, added: Date.now(), mock: true, tracks: 1 };
      state.albums.push(a); state.tracks.set(a.id, []);
    }
    sky.rebuild();
    const ws = sky.worlds(), rs = sky.regions();
    const hits = { onRegion: 0, onName: 0, onEachOther: 0 };
    for (const w of ws) {
      for (const G of rs) {
        if (Math.hypot(w.x - G.lx, w.y - G.ly) < G.r + w.r) hits.onRegion++;
        const overhead = Math.abs(w.x - G.lx) < G.r * .9;
        const top = G.ly - G.r * .9;
        if (overhead && w.y < top + w.r && w.y > top - 110 - w.r) hits.onName++;
      }
      for (const v of ws) if (v !== w && Math.hypot(v.x - w.x, v.y - w.y) < v.r + w.r) hits.onEachOther++;
    }
    /* the sky's own reach — a world should be within it, in the dark
       between the clusters, not banished to a rim nobody pans to */
    const skyR = Math.max(320, ...rs.map(G => Math.hypot(G.lx, G.ly) + G.r));
    const outside = ws.filter(w => Math.hypot(w.x, w.y) - w.r > skyR * 1.05).length;
    return { n: ws.length, ...hits, outside, skyR: Math.round(skyR),
      kinds: new Set(ws.map(w => w.type)).size };
  });
  ok("a world never sits on a genre's region", worlds.onRegion === 0, worlds);
  ok("nor under its name", worlds.onName === 0, worlds);
  ok("nor on another world", worlds.onEachOther === 0, worlds);
  ok("worlds stay within the sky, not exiled past it", worlds.outside === 0, worlds);
  ok("and there are several kinds of them", worlds.kinds >= 3, worlds);

  ok("a figure is a tree, one line per new record", fig.edges === fig.stars - 1, fig);
  ok("it is lopsided, not a ring", fig.spreadDeep > 0.15 && fig.spreadShallow > 0.15, fig);
  ok("large figures branch", fig.branched >= 4, fig);
  ok("a new record extends the figure", fig.grew && fig.kept, fig);

  ok("no errors while gesturing", errors.length === 0, errors);
  await ctx.close();
}

/* ── the transport answers the finger, and the shelf is level ──
   Every one of these was reported from a phone: a scrub thumb too small
   to hit, a player that stuttered while the sky burned frames behind it,
   and a grid of mismatched tiles. */
{
  console.log("\nthe transport");
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.route("**://itunes.apple.com/**", r => r.abort());
  await page.route("**://musicbrainz.org/**", r => r.abort());
  await page.goto(`http://localhost:${PORT}/`);
  await page.waitForTimeout(900);

  await page.evaluate(() => makeMockAlbums(8).then(m => onAlbumsAdded(m, 0, { quiet: true })));
  await page.waitForTimeout(3000);
  await page.evaluate(() => switchTab("library"));
  await page.waitForTimeout(600);

  const heights = await page.evaluate(() =>
    [...document.querySelectorAll("#libGrid .alb")].map(e => Math.round(e.getBoundingClientRect().height)));
  ok("every record is the same size on the shelf",
    heights.length > 3 && new Set(heights).size === 1, heights);

  ok("returning to the library keeps the cards it already built",
    await page.evaluate(async () => {
      const first = document.querySelector("#libGrid .alb");
      switchTab("sky");
      await new Promise(r => setTimeout(r, 200));
      switchTab("library");
      await new Promise(r => setTimeout(r, 300));
      return document.querySelector("#libGrid .alb") === first;
    }) === true);
  ok("an emptied grid is still rebuilt on arrival",
    await page.evaluate(async () => {
      document.querySelector("#libGrid").innerHTML = "";
      libShown = 0;
      switchTab("sky"); switchTab("library");
      await new Promise(r => setTimeout(r, 300));
      return document.querySelectorAll("#libGrid .alb").length;
    }) === 8);

  await page.evaluate(() => {
    const a = state.albums[0], trks = state.tracks.get(a.id);
    state.queue = trks.map(t => ({ albumId: a.id, trackId: t.id }));
    state.qIndex = 0; state.playingAlbumId = a.id;
    updatePlayerUI(a, trks[0], true);
    openSheet("sheetNow");
  });
  await page.waitForTimeout(500);

  const before = await page.evaluate(() => { switchTab("sky"); return sky.framesDrawn(); });
  await page.waitForTimeout(700);
  ok("the sky stops painting behind an open sheet",
    await page.evaluate(() => sky.framesDrawn()) === before);

  // a duration to scrub through, without needing a decodable file
  await page.evaluate(() =>
    Object.defineProperty(audio, "duration", { configurable: true, get: () => 200 }));
  const band = await page.evaluate(() => {
    const r = document.querySelector("#nowSeekWrap").getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  });
  ok("the scrub band is a target a thumb can hit", band.h >= 36, band);
  // press near the band's top edge, three quarters along — nowhere near the thumb
  await page.mouse.move(band.x + band.w * 0.75, band.y + 4);
  await page.mouse.down();
  await page.waitForTimeout(120);
  const held = await page.evaluate(() => +document.querySelector("#nowSeek").value);
  ok("pressing the band puts the playhead there", Math.abs(held - 750) < 40, held);
  await page.mouse.move(band.x + band.w * 0.25, band.y + 20, { steps: 8 });
  await page.waitForTimeout(120);
  const dragged = await page.evaluate(() => +document.querySelector("#nowSeek").value);
  ok("the playhead follows the finger anywhere on the band", Math.abs(dragged - 250) < 40, dragged);
  ok("scrubbing never pulls the sheet away",
    await page.evaluate(() => document.querySelector("#sheetNow").classList.contains("open")) === true);
  await page.mouse.up();
  await page.waitForTimeout(150);
  const landed = await page.evaluate(() => Math.round(audio.currentTime));
  ok("letting go commits the seek", Math.abs(landed - 50) < 10, landed);

  ok("no errors at the transport", errors.length === 0, errors);
  await ctx.close();
}

/* ── nothing reaches for a third-party script any more ── */
{
  console.log("\nprivacy");
  const { ctx, page } = await session();
  ok("the JSONP loader is gone", await page.evaluate(() => typeof jsonp === "undefined"));
  ok("no remote scripts are injected", await page.evaluate(() =>
    [...document.querySelectorAll("script[src]")].every(s => new URL(s.src, location.href).origin === location.origin)));
  await ctx.close();
}

await browser.close();
server.close();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
