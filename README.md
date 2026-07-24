# ISOLATION

*A music library that composes itself as a night sky.*

Every album you own becomes a star. Twenty stars knit a constellation.
A hundred wake a planet. Each install mints its own sky seed, so two
people with identical libraries still live under different skies.

Everything — audio, artwork, playlists, listening history — lives **on
the device only**. Nothing is uploaded, tracked, or shared. The only
network calls are optional metadata lookups (iTunes/Deezer) and the
recommendation scan, which links out to Bandcamp so discovery ends in
*owning* the music, not renting it.

## What's in here

```
app/                  the entire application (single-file PWA + service worker)
ios/                  Capacitor iOS shell, ready for Xcode
capacitor.config.json
package.json
```

## Get it on your iPhone

### A) Native app via Xcode (plug your phone in)

Needs a Mac with Xcode and free Apple-ID signing (no paid account required
for personal installs).

```sh
npm install
npx cap sync ios     # runs pod install, copies app/ into the shell
npx cap open ios     # opens Xcode
```

In Xcode: select the **App** target → *Signing & Capabilities* → pick your
Team (your Apple ID) → plug in your iPhone → choose it as the run
destination → press **Run**. The app installs and launches; data persists
in the app's own WKWebView storage and survives reboots and updates.

> An `.ipa` archive for distribution is *Product → Archive* from the same
> project once signing is set up.

### B) No Mac — install as a PWA today

1. Drag the `app/` folder into <https://app.netlify.com/drop> (or any
   static host).
2. Open the URL in Safari on the iPhone.
3. Share → **Add to Home Screen**.

Fullscreen, offline after first load (service worker), keeps your library.

## Collecting features

- **Zip import** — Bandcamp purchases arrive as `.zip`; import them
  exactly as downloaded. Stored *and* deflated entries are handled
  natively, folder art (`cover.jpg` etc.) is picked up automatically.
- **Protected storage** — persistent storage is requested the moment the
  first real album arrives; Settings shows whether the OS granted it.
- **Full backup / restore** — one tap writes every album, artwork,
  playlist, play count, and the log into a single zip. Restoring is just
  importing that zip again. Catalog-only JSON export included.
- **A unique sky** — per-install seed twists star placement,
  constellation names, planet types, and the dustfields.
- **Early ceremonies** — the sky answers at 1, 3, 5, and 10 albums, so a
  new collector feels progress long before the 20-star constellation.
- **The on-ramp** — a built-in collector's guide (where to buy DRM-free
  music, how to rip CDs, how backups work) plus recommendations that link
  to Bandcamp search for artists near your taste.
- **Share your sky** — renders the live sky into an image card for the
  share sheet. Only the picture leaves the device.
- **Player** — gapless-queue playback, 10-band EQ, shuffle, repeat
  off/all/one, lock-screen controls via Media Session.
