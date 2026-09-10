/* ISOLATION offline shell.
   The app itself (index.html) is NETWORK-FIRST: every launch with a
   connection gets the newest deployed version, and the cache only answers
   when offline. Static assets are cache-first. Bump CACHE on release so
   old caches are swept. Audio and library data live in IndexedDB, never
   here — updating the shell can't touch a user's collection. */
const CACHE = "aeon-v4.4.1";
const SHELL = ["./", "./index.html", "./interface.css", "./fonts/AeonNocturne-Regular.woff", "./manifest.webmanifest", "./icon-180.png", "./icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;

  const isApp = e.request.mode === "navigate" || /(?:^|\/)(index\.html)?$/.test(url.pathname);

  if (isApp) {
    // Network-first, but the cached app beats any *bad* answer, not just a
    // failed one: an outage, a captive portal, or a host that still resolves
    // after the site is gone and hands back its own 404 page. The library
    // lives in IndexedDB, so a working shell is the only thing standing
    // between the user and their collection — never replace it with an error.
    e.respondWith((async () => {
      try {
        const res = await fetch(e.request);
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put("./index.html", copy));
          return res;
        }
        return (await caches.match("./index.html", { ignoreSearch: true })) || res;
      } catch (err) {
        const hit = await caches.match("./index.html", { ignoreSearch: true });
        if (hit) return hit;
        throw err;
      }
    })());
    return;
  }

  e.respondWith((async () => {
    const hit = await caches.match(e.request, { ignoreSearch: true });
    if (hit) return hit;
    const res = await fetch(e.request);
    if (res && res.ok) {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
    }
    return res;
  })());
});
