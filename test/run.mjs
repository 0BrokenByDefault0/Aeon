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
import { fileURLToPath } from "url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.join(HERE, "..", "app");
const PORT = 8917;

let mode = "live";
const server = http.createServer((req, res) => {
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
