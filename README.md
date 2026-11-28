# ISOLATION

*A music library that composes itself as a night sky.*

ISOLATION is a native iPhone and iPad player for music you own. Every album
becomes a star, coloured by its own artwork. **An artist is a
constellation**: their second album draws the first line between them.
**A genre is a region**: every artist working in it clusters in the same
quarter of the sky. Every fifteen albums wakes a planet. Each install mints
its own sky seed, so two people with identical libraries still live under
different skies.

Everything lives **on the device**: audio, artwork, playlists and listening
history are never uploaded, tracked or shared.

> On the home screen and in Files the app is ISOLATION. Inside, it calls itself
> *Aeon*, which is also the name used in the code, the repository and build
> artefacts.

## Features

**Bring the whole collection at once.** No file picker survives a library of
tens of thousands of files. Copy your master folder into **Files → On My
iPhone → ISOLATION → Music** (artist folders, album folders, nested as deep
as you like) and tap **Adopt Library**. Adoption reads the files where they
lie: nothing is copied, so a 500 GB collection occupies 500 GB, and the scan
takes as long as reading the tags. Later scans read only new or changed
files, re-link moved folders and add new files to the albums they belong to.
Removing an album takes it out of the sky and leaves your file untouched.
For a handful of files, **Import** copies them in from Files instead.

**Tags you can trust.** Albums are named from their tags, and from the folder
when the tags are silent. Folders are told apart by their whole path, so the
many `Live` and `Disc 1` folders a big library contains never fuse into one
impossible record. Genres are folded before they are compared (case,
accents, `&` against `and`, plurals, ID3v1 codes, genuine synonyms), so
`Hip-Hop`, `hip hop` and `Rap` are one region, while the label keeps the
spelling you use. Albums with no genre are filled in from the artist's other
records, then from a small built-in table, and are marked as inferred. Edits
you make in the app never rewrite your files' tags.

**Playback built for collectors.**
- Gapless playback on AVAudioEngine, with lock-screen and Control Center
  controls, a Control Center play/pause control and Shortcuts actions.
- ReplayGain, a ten-band parametric equaliser and saved curves.
- Device correction: choose your headphone model from an offline catalogue
  of published measurements, or import an AutoEq / Equalizer APO profile.
- Embedded lyrics, a reorderable queue, shuffle and repeat.
- MP3, AAC / M4A, ALAC, FLAC, WAV, AIFF and CAF.

**Around the library.**
- Playlists, Favourites and M3U playlist import.
- Album detail and metadata editing, with optional artwork and genre lookup.
- One-file backup and transactional restore of the whole catalogue.
- A shareable picture of your sky. Only the picture leaves the device.
- Optional Spotlight indexing of album names, off by default.
- Adaptive iPhone and iPad layouts, Dynamic Type up to the largest
  accessibility sizes, VoiceOver navigation of the sky, and Reduce Motion.

## Privacy

The app makes network requests only for metadata lookups: when you tap
**Find Art** or **Look Up Genre**, or after an import if you turn on
automatic lookups in Settings (off by default). Those requests send an
album's title and artist to Apple and MusicBrainz, and nothing else. There is
no analytics, no advertising and no account. The app ships a privacy
manifest declaring no tracking and no collected data.

## Requirements

- iPhone or iPad running iOS / iPadOS 26.
- To build: a Mac with Xcode 26, Node.js (LTS) and CocoaPods.

## Build and run

```sh
npm ci                       # JavaScript tooling and Capacitor
npx cap sync ios             # prepares the native project and runs pod install
open ios/App/App.xcworkspace # always the workspace, not the project
```

In Xcode, select the **App** target, open **Signing & Capabilities**, tick
*Automatically manage signing* and choose your team (a free Apple ID works).
If the bundle identifier `app.isolation.sky` is taken, add a suffix of your
own. Pick your device as the run destination and use **Product → Run**
(Cmd-R). On first launch, trust your developer certificate on the device
under **Settings → General → VPN & Device Management**.

Apps signed with a free Apple ID stop opening after seven days; run again
from Xcode to renew. Your library is not affected. CarPlay additionally
requires Apple's CarPlay audio entitlement for your team.

### Without a Mac

Pushes to the repository build an unsigned iteration IPA on a hosted Mac:
**Actions → Build fast unsigned IPA → the newest run → Artifacts**. Sign and
install it with a sideloading tool such as [AltStore](https://altstore.io),
SideStore or [Sideloadly](https://sideloadly.io). Each IPA embeds a
validation manifest; it is an iteration build, not a release.

## Development

```
ios/App/App/          the native app: SwiftUI screens, Metal sky, AVAudioEngine
                      playback, SQLite catalogue, importer and 4.x migration
ios/App/AeonWidgets/  Control Center and widget extension
ios/App/AppTests/     XCTest unit and integration tests
ios/App/AppUITests/   XCUITest flows and screen matrices
app/                  the 4.x web app, kept only to migrate existing libraries
tests/                Node source contracts and core checks
test/                 browser regression suite over the 4.x web app
scripts/              syntax check, targeted test routing and packaging
docs/                 development workflow, validation matrices, release notes
```

```sh
npm test                                         # Node contracts and core checks
npm run check                                    # syntax check
npm run test:targeted -- --area=playback         # cheap checks for one area
npm run test:targeted:native -- --area=playback  # focused XCTest (macOS)
npm run test:ios                                 # full iPhone and iPad simulator suites (macOS)
```

Areas are `import`, `playback`, `library`, `sky`, `chrome`, `playlists` and
`settings`. The working loop, validation labels and the release checklist are
in [`docs/development-workflow.md`](docs/development-workflow.md); release
notes are in [`docs/releases/`](docs/releases/). Contributors and coding
agents should read [`AGENTS.md`](AGENTS.md) first.

Capacitor remains a dependency for one job: the hidden web view that reads a
4.x library out of browser storage during the first 5.0 launch.
