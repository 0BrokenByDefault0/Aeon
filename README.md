# ISOLATION

*A music library that composes itself as a night sky.*

Every album you own becomes a star. **An artist is a constellation** —
their second album draws the first line between them. **A genre is a
region** — every artist working in it clusters in the same quarter of the
sky. Every twenty albums wakes a planet, which presides over the twenty
that raised it. Each install mints its own sky seed, so two people with
identical libraries still live under different skies.

Everything — audio, artwork, playlists, listening history — lives **on
the device only**. Library content is never uploaded, tracked, or shared.
The only application-data network calls are manual metadata lookups,
automatic metadata lookups that the collector explicitly enables in
Settings (off by default). Metadata requests send the album title and
artist to Apple and MusicBrainz as data-only HTTP requests; third-party
scripts never run inside the app. Recommendations need no network at all —
they read your own library for artists you own exactly one record by — and
link out to Bandcamp, so discovery ends in *owning* the music, not renting
it.

**Bring the whole collection at once.** No file picker survives a library
of tens of thousands of files, so the installed app doesn't use one:
copy your master folder into **Files → On My iPhone → ISOLATION →
Music** — artist folders, album folders, nested as deep as you like —
and tap **ADOPT LIBRARY**. Every folder holding audio becomes one album,
tagged from the files themselves and named from the folder when the tags
are silent. Folders are told apart by their whole path, so the several
`Live` and `Disc 1` folders every big library contains never fuse into
one impossible record.

Adoption reads the files **where they lie**: nothing is copied, so a
500 GB collection occupies 500 GB rather than a terabyte, and it takes
as long as reading the tags, not as long as duplicating the audio.
Because those files are yours and not the app's, removing an album later
takes it out of the sky and leaves the file on disk untouched.

**No storage cap.** In the native app the audio is written to the device's
own filesystem rather than into browser storage, streamed from disk at
playback, and never held in memory. The ceiling is the space on the phone,
not a quota. Because the folder is Documents, the whole collection appears
in **Files → ISOLATION → Music** and can be copied in or out wholesale —
the only workable way to move a library measured in hundreds of gigabytes.

## How it looks

One colour and one material. The interface is black and a single warm
bone; the only saturated colour anywhere arrives with the record that is
playing, which tints the seek line, the glow beneath the sleeve and the
star of the album in the grid. Names are set in a tight grotesk, anything
countable in monospace with tabular figures. Boxes were retired in favour
of hairlines and space.

The sky is a place rather than a diagram. Regions are marked by a breath
of their own light instead of a drawn boundary; genre names read from
orbit and artist names on approach, never both at once. **No
constellation is a polygon.** Each artist's figure is *grown* from their
name rather than laid out on a circle: a spine that wanders, limbs that
branch off it once the artist runs deep enough, no two arms the same
length, and nothing closing back on itself. Because it grows in
sequence, buying their next record extends the figure instead of
rearranging the shape you already recognise. Worlds are not painted, they
are drawn — in the same colour at the same hairline weight as everything
else, and their mass shows in what they hide rather than in what they
put on screen: a world is a place the stars are not. One line closes it,
bright where the sun strikes and gone by the terminator, with a
graticule engraved across it like a globe on an atlas plate. They differ
in what is ruled on them, never in colour, and they stand in the dark
between the genre clusters — never over a region, never under its name.

The camera is a critically damped spring, so it settles
without ever ringing, and on launch the collection assembles outward from
the centre. There is no film grain; instead the transmission stutters
every so often, a couple of hairline bands for a tenth of a second.

Sheets are objects, and the handle at the top of one is not decoration:
pull down and the sheet tracks your finger while the dark behind it
thins, let go past a quarter of its height — or throw it — and it
leaves. Pull *up* on the player bar and the full player arrives; pull up
on the sleeve inside it and the rest of the queue does.

The handle is a band across the whole top of the sheet rather than the
hairline you can see, and it is the one surface a scroller can never
take, so pulling it works even on a sheet that is mid-scroll. Away from
the handle the gesture defers: it engages only when the sheet is already
at its top and the movement is clearly vertical, and stands down
entirely if the browser has already committed the touch to scrolling.
The player itself never scrolls — on a short phone the sleeve gives up
height rather than pushing the transport off the bottom.

## What's in here

```
app/                  the entire application (single-file PWA + service worker)
ios/                  Capacitor iOS shell, ready for Xcode
tests/                unit tests over the deterministic core (npm test)
test/                 browser regression suite (npm run test:browser)
scripts/              syntax check and dependency patches
.github/workflows/    verify.yml (CI) and ios-ipa.yml (unsigned IPA)
capacitor.config.json
package.json
```

## The unsigned .ipa

Apple only permits iOS binaries to be produced on macOS, so the build runs
on a hosted Mac in CI. Every push builds `ISOLATION-unsigned.ipa` and
attaches it to the run: **GitHub → Actions → "Build unsigned IPA" → the
newest run → Artifacts**.

It is deliberately unsigned, which is what sideloading tools expect —
[AltStore](https://altstore.io), SideStore or
[Sideloadly](https://sideloadly.io) sign it with your own Apple ID on your
own machine. That signature is the one part no build server can produce
for you, because it is yours. With a Mac to hand, the Xcode route below is
faster and gives a properly signed build.

## Tests

```sh
npm test                 # unit tests over the deterministic core
npm run test:browser     # drives the real app in a browser
npm run check            # syntax check
python3 test/fixtures.py # regenerate the audio fixtures
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
