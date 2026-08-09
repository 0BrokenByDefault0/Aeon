# ISOLATION

*A music library that composes itself as a night sky.*

Every album you own becomes a star. **An artist is a constellation** —
their second album draws the first line between them. **A genre is a
region** — every artist working in it clusters in the same quarter of the
sky. Every twenty albums wakes a planet, which presides over the twenty
that raised it. Each install mints its own sky seed, so two people with
identical libraries still live under different skies.

**A transit crosses the sky every night** — a comet carrying a record you
have neglected, a supernova on the album you have played to death, a
meteor shower of fourteen songs shaken loose at random, an eclipse over
the one you never returned to, or an alignment binding two of your
constellations into a single playlist. The date and your sky seed decide
it together, so it holds all day, is gone by morning, and is never the
same in two collections. Following one is recorded.

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

### A) The real native app (needs a Mac, once)

Everything in `ios/` is a complete Xcode project — background audio, the
app icon, permission strings and the file-export bridge are already
configured. You never open Xcode's settings except to pick your name in
the signing dropdown.

**One-time setup on the Mac**

1. Install **Xcode** from the Mac App Store (free, large — start this
   first, it is the slowest step). Open it once and accept the licence so
   it finishes installing components.
2. Install **Node** (<https://nodejs.org>, LTS) if you don't have it.
3. Install **CocoaPods**: `brew install cocoapods` — or, without Homebrew,
   `sudo gem install cocoapods`.

**Build and install**

```sh
cd Aeon           # the project folder
npm install       # fetches Capacitor
npx cap sync ios  # copies app/ into the shell and runs pod install
npx cap open ios  # opens App.xcworkspace in Xcode
```

Then, in Xcode:

4. **Xcode → Settings → Accounts → +** and sign in with your Apple ID
   (a free one is enough — no paid developer account needed).
5. In the left sidebar click the blue **App** project → the **App**
   target → **Signing & Capabilities** tab. Tick *Automatically manage
   signing* and choose your name under **Team**. If it complains the
   bundle identifier is taken, change `app.isolation.sky` to something
   like `app.isolation.sky.yourname`.
6. Plug the iPhone in with a cable, unlock it, and tap **Trust** if asked.
7. At the top of the Xcode window, set the run destination (next to the
   ▶ button) to your iPhone.
8. Press **▶** (or ⌘R). The app builds and installs.
9. The first launch is blocked by iOS: on the phone go to **Settings →
   General → VPN & Device Management**, tap your Apple ID, and
   **Trust**. Then open ISOLATION from the home screen.

**Worth knowing:** an app signed with a *free* Apple ID stops opening
after 7 days — plug in and press ▶ again to renew it, which does not
touch your library. A paid developer account ($99/yr) extends this to a
year and lets you export a shareable `.ipa` via *Product → Archive*.

No Mac of your own? A rented cloud Mac works with exactly the same steps.

### B) No Mac — install as a PWA today

Apple only allows iOS apps to be built and signed on macOS, so without one
this is the way in — and it is the same app, offline-capable, with its own
icon and no browser chrome.

1. Drag the contents of `app/` onto <https://app.netlify.com/drop>.
2. Open the URL it gives you in **Safari** on the iPhone.
3. **Share → Add to Home Screen**.

The only thing the PWA gives up is audio surviving a swipe-away from the
app switcher; locking the screen and backgrounding are fine.

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
