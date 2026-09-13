# Aeon — SwiftUI design handoff

Design specification for the native iPhone/iPad SwiftUI rebuild.

**Scope of this document:** visual and interaction design only. Architecture,
persistence, audio integration, migration strategy and test plan are Codex's,
and nothing here should be read as constraining them.

**Status of the Capacitor build:** behavioural reference material. `app/index.html`
and `app/interface.css` are the authority on *what the app currently does*; they
are not a target to port line by line. Where this document and the web build
disagree, this document wins — those are deliberate corrections.

**Source of truth for the sky's meaning:** the grammar in §4. It is settled and
should not be re-litigated during implementation.

---

## 1. Visual north star

> Aeon is not an app displaying a star map. It is an instrument for observing a
> sky, and every surface that isn't sky is part of the instrument.

The sky is the ground of the app — a real, navigable, procedurally composed
space. Everything else is machined glass laid over it: near-clear silver
panels, hairline edges catching light, square corners, white typography. No
rounded cards, no filled buttons, no ornament.

**Mood:** an observatory at night. Cold, quiet, precise, mostly empty. The
restraint is the point — a star chart is mostly void, and that is what makes
the marks legible.

**Five commitments:**

1. **Light is the only material.** Nothing in the sky has a fill, stroke or
   shadow — things glow or they are absent. The instrument may have surface;
   the sky never does.
2. **Catalogue conventions carry the information.** Magnitude encodes
   listening, figure lines are lighter than the stars they join, a legend sits
   in the corner. Star charts solved these problems centuries ago.
3. **One accent, and it belongs to the present tense.** See §6 — the accent is
   sampled from the playing album's artwork and marks only what is playing.
4. **Motion is physics, not transition.** Zoom is flight. Pan has momentum.
   Nothing springs, slides or fades the way the OS would do it by default.
5. **Emptiness is composition.** Resist filling the middle-zoom screens.

**Inherited non-negotiables** (already in the repo's root `AGENTS.md`, still
binding): never introduce emoji into UI, source, docs or test output — named
SVG/SF Symbol icons or plain text only. Preserve the near-clear silver glass,
white typography, square borders and vibrant sky. Preserve user-owned music
metadata.

---

## 2. Screen hierarchy

```
Root
├── Airlock (first-run / cold-launch overture, skippable, dismissed once)
└── Shell
    ├── Sky            ← the persistent ground, always rendered
    │   └── Sky chrome  (HUD, star label, capture, ceremony banner, void invite)
    ├── Library        ← sheet-over-sky
    ├── Playlists      ← sheet-over-sky
    ├── Settings       ← sheet-over-sky
    ├── Player bar     ← persistent above the dock whenever a track is loaded
    └── Dock           ← 4 tabs
```

The Sky is not a tab that replaces the others. It is the floor. Library,
Playlists and Settings are panels that rise over a Sky that keeps living
underneath, and the Sky's rendering is never torn down when one is open.

**This is the single most important structural change from the web build**,
where the Sky is tab 01 of 04 and reads as decorative.

### Sky zoom tiers

One continuous zoom, not discrete screens. Scale clamps to `0.08 … 6.0`.

| Altitude | Shows | Labels |
|---|---|---|
| Far | whole sky, region names | region names only |
| Region | one genre's constellations | region + constellation names |
| Constellation | one artist's figure | constellation name, star names on approach |
| Star | one album | album name, opens the album sheet on tap |

Labels fade in and out by altitude rather than appearing or vanishing at
thresholds. In the current build the constellation tier has **no label at all**
— that is a bug this spec corrects.

---

## 3. Navigation model

- **Dock:** Sky · Library · Playlists · Settings. Four peers, no ordinal
  numbering (the web build's `01`–`04` pseudo-element counters are removed —
  numbering claims a sequence that does not exist).
- **Altitude strip:** a persistent breadcrumb below the top safe area on the
  Sky, e.g. `SKY / R&B · SOUL / DOCTOR VELOUR`. Each segment is tappable and
  flies the camera back out to that tier. It is simultaneously the screen
  title, the zoom-out affordance, the only cue that pinch is available, and
  the teaching mechanism for the whole grammar — three flights and the user has
  learned that a constellation is an artist without reading a word.
- The same component renders the `AEON / YOUR COLLECTION` breadcrumb at the top
  of every panel. One component, one grammar, everywhere.
- Panels dismiss by dock tap, downward drag, or swipe from the left edge.
- Sheets stack at most two deep. A third replaces rather than stacks.

---

## 4. The sky grammar (settled)

| Mark | Means | Figure lines |
|---|---|---|
| star | one album | — |
| constellation | one artist, 2+ albums | yes |
| lone star | one artist, exactly 1 album | no |
| cluster | Various Artists | no |
| region | one genre | — |
| planet | one era of N albums | traces, only while selected |

**The line rule:** figure lines mean one artist made more than one of these. A
lone star has nothing to connect to. Various Artists is not a person, so it
draws no figure — it reads as a dense field of unjoined stars in its own
region, which needs no size cap because there is no figure to tangle.

### Placing a star

First match wins:

1. Compilation / Various Artists → the VA cluster, in its own region.
2. Artist's albums agree on genre → that region, from local tags, no lookup.
3. Artist spans genres → external source's canonical artist genre, applied to
   every album by them.
4. Lookup off, unavailable or empty → most frequent genre across their albums;
   ties break toward the earliest-added album so the result is deterministic.
5. No usable tags at all → Uncharted.

Step 4 is mandatory: automatic metadata lookups ship **off by default** and the
app must work fully offline. Placement can never depend on a network call.

**External source:** MusicBrainz first, Apple second. Cache the artist→genre
answer permanently on first success — asked once per artist, never per album,
and never re-asked in a way that could move a placed star.

### Coordinates

- Assigned once, at placement, never recomputed.
- New artists fill outward from the origin, so **distance from origin encodes
  time**.
- Exactly two things move a star, both user-initiated: charting it out of
  Uncharted, and manual tag editing. No importer, rescan or migration ever
  moves one.

### Uncharted

A real region, not an error state — everything not yet surveyed.

- Provisional coordinates seeded from a hash of the album ID, never arrival
  order, so the region is identical every launch and can be worked through
  methodically.
- Cold and unresolved: no figure lines, no region glow, no nebula, low
  magnitude. Not red, not alarming.
- **`47 UNCHARTED` is the app's entire tagging notification system.** No
  badges, no prompts, no "missing metadata" dialogs.

**Charting is the reward.** When an album is tagged and can be placed, its star
lifts out of Uncharted, travels across the sky to its permanent coordinate, and
joins its artist's figure lines as it settles. Batch tagging sends many at once
— staggered departures, varied arrival times, the region dimming as it empties.
Metadata cleanup is the least pleasant work in any local library and the work
Aeon most needs done; this is how it gets paid for.

Re-tagging a placed album is allowed, and acknowledged with a quiet
confirmation naming what moves: `This will move 3 stars`.

### Planets

- One planet per N albums added (**N is unresolved — see §19**).
- A planet **is** its N albums: bound at formation, ordered by import date, and
  **immutable forever**. Not addable to, removable from, or reorderable. The
  moment it becomes editable it collapses into an ordinary playlist and loses
  the only thing that made it worth having — that it is a true record rather
  than a curated one.
- **A planet does not contain its stars.** Stars stay where they live.
  Selecting a planet dims the sky, brightens its member stars wherever they
  are, and draws traces from the planet out to each. Traces render from current
  positions — never cache a star position inside a planet.
- Planets form at the **frontier**: the outer edge of the sky as it stood when
  the last album of the era landed, in the void between regions. They belong to
  no region, which is correct, because an era doesn't either.
- Appearance generated from contents: band colours sampled from the member
  artwork, rotation from average tempo, turbulence from dynamic range, rings
  only when the era was genre-pure. Vibrancy inherited from member magnitudes —
  a well-listened era glows, a neglected one orbits cold.
- **Deterministic:** every visual parameter derives from a hash of the member
  album IDs plus planet index. A reinstall or restore must regenerate
  byte-identical planets in identical positions. A landmark that changes
  appearance is worse than no landmark.
- Stored at formation: ordered album IDs, each import timestamp, the frontier
  radius at that moment, the derived seed.
- **Backfill on first launch:** walk existing albums in import order, form a
  planet every Nth, recover each frontier radius from the coordinates
  themselves (the furthest star imported up to that point). Starting the count
  at zero leaves the inner sky — everything collected first — permanently
  without landmarks.

### Magnitude

Brightness encodes **listening**, not acquisition. An album played through
burns bright; one imported and never opened sits near the threshold of
visibility. This is what turns the sky from a map of what you own into a map of
what you actually listen to.

---

## 5. Typography

| Role | Face | Use |
|---|---|---|
| display | `AeonArthemys`, falling back to `Aeon Nocturne` | names of things — screen titles, album titles, playlist names, planet names |
| UI | SF Pro (system) | rows, body copy, buttons, settings |
| mono | SF Mono (system) | labels, counts, durations, coordinates, catalogue numbers |

Display sizes: 60 / 40 / 34 / 24. UI: 17 / 15 / 14 / 13 / 12 / 11. Mono: 10–11,
uppercase, tracking `+0.15em…0.22em`.

Display type is set light, tight (`-0.035em…-0.045em`) and large. Uppercase
mono labels are the only tracked-out type in the app.

Tabular figures (`.monospacedDigit`) wherever digits align: track numbers,
durations, counts, EQ values, timecodes.

**Asset warning:** `AeonArthemys` is referenced five times in the web build but
**no font file for it exists in `app/fonts/`** — it is silently falling back.
`AeonNocturne-Regular.woff` is the only display face actually present. Either
source the real file or standardise on Nocturne before implementation. See §19.

---

## 6. Color

The palette is near-monochrome silver on black. The only chroma in the app
comes from artwork.

| Token | Value | Role |
|---|---|---|
| `void` | `#000000` | the sky, and the app's ground |
| `bone` | `#F1F3F7` | primary text, brightest stars |
| `bone2` | `#BEC4CF` | secondary text |
| `bone3` | `#A0A9B8` | tertiary text — the floor for anything readable |
| `edge` | `rgba(236,244,255,0.27)` | lit edges on glass |
| `rule` | `rgba(223,233,248,0.135)` | hairline dividers |
| `tint` | dynamic, default `#C39DFF` | **the accent** |

**`tint` is sampled from the currently playing album's artwork** and recoloured
on every track change. This system already exists in the web build and is
better than a fixed accent — keep it. It marks the playing star, the seek fill,
the playing row, the now-playing card glow, and nothing else. When nothing is
playing there is no accent anywhere.

Semantic colour is deliberately absent: warnings and destructive states are
carried by form, position and confirmation copy, not hue.

---

## 7. Spacing, radii, materials, shadows

**Spacing scale:** 4 · 8 · 12 · 18 · 24 · 32 · 48. Panel side padding 24
(18 under 360pt width). No other numbers.

**Corner radii: all zero.** Square is a defining decision, not a preference.
The one exception in the current build is the featured transport glyph on the
listening card, which is a 36pt circle — keep that exception, drop no others.

**Materials — the silver chamber:**

- `glass` — `rgba(186,197,216,0.035)` over a 32pt blur, saturation ~126%,
  contrast ~105%. Used on panels, dock, player bar, sheets, HUD.
- `glassControl` — `rgba(188,199,218,0.026)`, for buttons and inputs.
- `refraction` — a 122° gradient running white→tint→pink at very low alpha
  across every glass surface, which is what makes it read as a physical pane
  rather than a translucency effect.
- `facet` — the edge lighting: `inset 0 1 0 rgba(255,255,255,.38)`,
  `inset 1 0 0 rgba(202,223,255,.07)`,
  `inset -1 0 0 rgba(255,204,239,.045)`,
  `inset 0 -1 0 rgba(0,2,7,.72)`, plus `0 18 48 rgba(0,0,0,.24)`.

In SwiftUI this is a custom material, not `.ultraThinMaterial` — the stock
materials sample and tint toward the system palette and will not hold this
look. Build it as a blurred backdrop plus the refraction gradient plus explicit
inset borders.

**The one material bug to fix:** over the album grid, the player bar and dock
currently sample the artwork behind them and the now-playing text becomes
unreadable. The glass stays, but a fixed dark scrim goes beneath it so contrast
holds against the brightest artwork in any library. Tested against the
brightest cover, not the average one.

**Shadows** are used only to lift glass off the sky and artwork off glass.
Nothing else casts.

---

## 8. Animation timing

| Motion | Duration | Curve |
|---|---|---|
| button press | 120ms | easeOut, scale 0.988 + 1pt translate |
| control state change | 180ms | easeInOut |
| panel in | 280ms | custom ease |
| sheet present / dismiss | 320ms / 280ms | interactive spring, drag-tracking |
| tab change | 220ms | easeInOut |
| sky flight (zoom tier) | 600–900ms | one shared curve, distance-scaled |
| star charting flight | 1.2s | ease-in-out, staggered 60ms in batches |
| planet formation | 6–8s | accretion, uninterruptible but fully escapable |
| airlock doors | 1.5s | `cubic-bezier(.64,0,.2,1)` |

**One flight curve** for every camera move in the sky. Pan carries momentum and
can be thrown.

**Planet formation** is the most expensive animation in the app and should be.
It is rare, and it is the thing people screen-record: the last album of the era
lands as an ordinary star in its constellation; out at the frontier dust draws
inward; a body accretes over 6–8s while the camera pulls back to frame it; as
it settles, traces reach out and touch each member star in import order — the
one time the app shows the shape of what was just finished — then fade. No
modal, no confetti, no dismissal. The user can fly away mid-formation and it
will be there when they return.

---

## 9. Sky presentation and interaction

Two composited layers: a nebula/atmosphere layer beneath, a world layer of
stars, figures and planets above. Plus a grain overlay and a dim layer used
when panels are open.

**Rendering:** Metal. The reason is bloom — everything separating "telescope"
from "space wallpaper" is post-processing on an HDR buffer (bright-pass,
downsampled blur chain, composite). SpriteKit's `SKEffectNode` + Core Image
path clamps to standard range, so bright stars stop getting brighter and the
field goes muddy. From the same pipeline: instanced point sprites with additive
blending and true magnitude; parallax as depth layers with different scroll
multipliers in one draw; nebulae as an fbm-noise pass at quarter resolution;
spectrum as an FFT band buffer in uniforms.

**Scope it tightly: Metal draws the sky and nothing else.** All chrome, sheets,
rows and labels stay SwiftUI on top, which keeps text rendering, Dynamic Type
and VoiceOver in the framework that does them properly.

**Gestures (canvas claims all of them; page never zooms):**

| Gesture | Result |
|---|---|
| drag | pan, with momentum |
| pinch | zoom about the pinch midpoint, which stays pinned under the fingers |
| tap on a star | open that album's sheet |
| tap on a constellation | fly to it |
| tap on a planet | select it — sky dims, member stars light, traces draw |
| tap on empty void | dismiss selection / deselect |
| double-tap empty | zoom out one tier |
| long-press (>600ms) | suppressed as a tap; reserved for context menu |

Movement beyond 12pt or a hold beyond 600ms is not a tap.

**Sky chrome** (visible only on the Sky, hidden whenever a panel or sheet is
open): altitude strip, HUD, star label, capture button, ceremony banner, void
invite.

**HUD** — a small mono readout, toggleable in Settings: albums adrift,
constellation count, progress toward the next planet, and the now-playing line.
Keep the existing voice (`albums adrift`, not `Albums: 47`).

**Ceremony banner** — the quiet announcement when a constellation forms or a
planet wakes. Tag line in mono, name in display face. It should never block or
require dismissal.

**Void invite** — the empty state. `A place for your records.` with an import
action and a "how it works" secondary. This is the best-composed screen in the
current build; carry it over nearly unchanged.

**Capture** (currently an unlabelled bolt icon in the corner) produces a clean
shareable image of the current sky view. This is the most hidden control in the
app and it is the one that produces all of Aeon's marketing — every screenshot
anyone ever posts comes from it. Promote it into the altitude strip as
`CAPTURE`, and make the output deliberate: chrome removed, labels rendered at
full strength rather than ambient faintness, region or constellation name set
properly, and a small engraved credit line — designation, date, star count. A
plate, not a screenshot. Offer the current framing and a wider one.

**Spectrum reactivity.** Currently on by default and barely perceptible. The
fix is coupling, not amplitude: lows drive nebula breath (slow, volumetric,
region-wide), mids drive the playing star's glow radius, highs drive brief
diffraction spikes on nearby stars. Asymmetric smoothing — ~30ms attack,
~400ms release; symmetrical smoothing is what makes audio reactivity look
cheap. Localise the response around the playing star so it doubles as a
locator. Normalise against a running track peak, not absolute level. Expose it
as Off / Ambient / Full with Ambient as default, at roughly double the current
strength.

---

## 10. Library

**Header:** breadcrumb kicker, display-face title, import action, one subtitle
line.

The current build states two different counts in two different type systems
("2 artists · On this device" and "23 records"). **One count line, stated
once, in the app's own units.**

**Continue listening card** — artwork, kicker, title, artist, and the circular
transport glyph. Tapping the artwork opens the album; tapping the glyph
toggles playback.

**Control bar** — one row: search, sort, and density (grid/list). The current
build stacks five separate control idioms in about 200pt of vertical space
(a circular button, a mono count, a segmented toggle, a rounded search field,
underlined sort tabs). Collapse to one bar built from the shared primitives,
and remove the circular play button — it is the only circle in the app.

**Sort:** Recent · Artist · Title · Year · Played. Horizontal, scrollable,
underline indicator.

**Grid:** 2 columns compact, 3 at ≥600pt, 4 on iPad. Square artwork, hairline
border, offset outline, title and artist beneath. The playing album carries the
tint and a `PLAYING` / `IN THE PLAYER` mono marker.

**List (compact):** 62pt artwork, title, artist, mono detail line, hairline
separators.

Search filters albums, artists and songs; song matches appear in their own
titled results group. Recommendations sit in a card below the grid.

---

## 11. Album sheet

Centred artwork with offset outline, kicker, display-face title, and a metadata
line of artist · year · genre.

**Header actions:** `PLAY` and `FIND IN SKY`. Find in Sky is promoted from the
bottom of the sheet into the header — it is the app's thesis, not a footnote,
and its current position beneath `REORDER TRACKS` is the clearest sign that the
Sky has been demoted to a feature of the list.

**Tracklist:** number, title, artist, per-row overflow button. The playing row
carries the tint and a left rule.

**Secondary actions**, grouped rather than dumped: `EDIT` opens the editor;
Reorder and Merge live under it; Add to Playlist stands alone. **Delete leaves
the button row entirely** and lives in overflow, confirming by name.

The current build presents five near-equal buttons in two rows with Delete
distinguished only by a dashed border — which reads as *disabled*, not
*destructive*. Dashed borders are not used anywhere in the new design.

**Editor:** title, artist, year, genre, plus lookup, find-art and pick-art
actions. Never render a null as a token — no `<unknown>`, no `0000`. Omit the
field, or offer it as an invitation (`ADD YEAR`).

---

## 12. Now playing

Full-height sheet over the sky.

Position indicator (mono) and heading · artwork stage — a lit glass frame with
offset outline and a tint-coloured radial bloom behind it · display-face title,
two lines max · artist · playback status line · seek bar with elapsed and
remaining in mono · transport (previous / play / next), play at 68×62 ·
shuffle, repeat, queue · volume · secondary action row.

**`LOCATE` belongs here.** The playing album already burns in the sky; what is
missing is the return path. Locate flies the camera to the playing star from
anywhere in the app. Target: two taps from any screen to see where the current
track lives.

**Mini player bar** — artwork, title, artist, play, next, and a 2pt seek fill
along the bottom edge. Tapping anywhere but the controls expands to the full
player. Titles must not truncate mid-word in a bar with room to spare.

EQ and Spectrum controls move here from Settings, where you can hear what you
are changing and watch the sky answer it.

---

## 13. Queue

Reachable from the player. Rows are drag-reorderable with an explicit 44pt drag
handle — not a long-press, which competes with the context menu.

Drop target shows a 1pt outline and a lifted background; the moving row drops
to 0.6 opacity. Actions: clear upcoming, save queue as a playlist (inline name
field), and a status line. The playing row is pinned and not reorderable.

---

## 14. Playlists

Display-face title, breadcrumb kicker.

Creation moves behind a `+` in the header — the current build keeps a name
field and CREATE button permanently above the list, giving a once-in-a-while
action top billing forever. The empty state keeps an inline create, because
there it *is* the primary action.

Rows: playlist name in display face, mono count beneath, hairline separators.

**Empty state:** `No routes charted yet.` — keep the copy, replace the generic
music-note glyph with a celestial mark (a dotted route between two points).
Every empty state in the app gets a celestial mark, never a system symbol.

---

## 15. Settings

Currently ten identically-bordered cards in one undifferentiated scroll, where
finding the EQ means scrolling past a factory reset. Regroup into three named
sections plus a plainer footer:

- **PLAYBACK** — sleep timer, EQ *(moving to the player)*, spectrum *(moving to
  the player)*
- **LIBRARY** — one import/one album, automatic metadata lookups, artwork
  repair, storage meter
- **THE SKY** — HUD, sky contrast, motion
- **footer** — backup (full `.zip`, catalogue-only `.json`), activity log,
  erase everything

**Toggles must read their state from fill, not only knob position.** Both
Importing toggles in the current build are visually indistinguishable from one
another, so the user cannot tell what is on. Filled tint track when on, bare
hairline track when off.

**Selection must add contrast, never remove it.** The active EQ preset is
currently the only one that cannot be read — dark on dark while the four
inactive presets read clearly.

**The sample-data generator** (`+1`, `+20`, `FILL TO 100`, `REMOVE SAMPLES`)
is developer tooling sitting above everything a real user came for. It does not
ship in the native app.

Keep the existing copy wholesale — the metadata-lookup explanation, "the sky
goes dark", the EQ preset names (`BASS RITUAL`, `VOCAL CULT`, `AIRWAVE`,
`TUNNEL`). The writing is the best thing in the app.

---

## 16. States

| State | Treatment |
|---|---|
| **empty (first run)** | Void invite over an empty sky. No spinner, no zero-counts. |
| **loading / scanning** | The sky fills star by star as the scan runs. Progress bar with count and current item. The highest-stakes screen in the app and the easiest to leave as a spinner. |
| **empty (filtered)** | Distinct from first-run: "nothing matches", with the filter visible and clearable. |
| **playing** | Tint present on the playing star, seek fill, playing row. HUD now-line visible. |
| **paused** | Tint persists — the album is still *in the player*. Row marker reads `IN THE PLAYER` rather than `PLAYING`. |
| **error** | Inline, in the app's voice, saying what failed and what to do. Never a system alert for a recoverable problem. |
| **unavailable (file missing)** | Row dimmed with a mono `FILE MISSING` marker, still tappable to locate or remove. The star dims but is never deleted from the sky without the user's action. |
| **offline** | Not an error state. Lookups silently fall back to local tags per §4. |
| **uncharted** | See §4 — a region, not an error. |

---

## 17. Layout

### iPhone (compact)

Single column. Panel side padding 24 (18 under 360pt). Grid 2 columns. Dock
pinned bottom with the player bar directly above it. Sheets present from the
bottom, full-width, top-aligned to just under the top safe area.

### iPad (regular)

The extra space goes to **the sky**, not to more chrome. Specifically:

- **Sky stays edge to edge and full-bleed.** It is the reason to use the app on
  a larger screen; a wider sky shows more of the collection at once.
- **Sidebar navigation** replaces the dock — Sky, Library, Playlists, Settings
  as a list, collapsible, with the sky visible beside it.
- **Library grid at 4–5 columns**, artwork larger rather than merely more
  numerous.
- **Album sheet becomes a side panel**, not a bottom sheet — sky on the left,
  album on the right, so `FIND IN SKY` can highlight the star *while you are
  looking at the album*. This is the single most valuable thing the extra space
  buys.
- **Now playing as a detail pane** rather than a full-screen takeover.
- **Planet selection shows traces across a genuinely wide sky**, which is where
  the era view finally reads properly.
- Content max-width ~900pt for text-heavy panels; never full-width body copy.

Do not add an inspector, a second toolbar, or a persistent queue rail. The
instrument stays small; the sky grows.

### Portrait and landscape

- **iPhone portrait** — primary. Everything above.
- **iPhone landscape** — supported, not optimised. The sky is full-bleed and
  gets the whole screen. Panels become a left-aligned column at ~480pt, not
  full-width. The player bar shortens. Now-playing moves artwork left and
  controls right rather than stacking.
- **iPad both orientations** — first class. Sidebar persists in landscape,
  collapses to an overlay in portrait.
- Sky camera position, zoom, and selection survive every rotation. Nothing in
  the sky reflows on rotation — the camera reframes, the coordinates never
  change.

---

## 18. Safe areas, Dynamic Type, accessibility

**Safe areas.** One container owns them. The sky draws edge to edge beneath
everything including the status bar; all legible content lives inside the
insets.

The single most damaging bug in the current build is that this is not true at
either end: Settings renders its section heading *through* the status bar clock
and behind the Dynamic Island, and content runs under the player bar and dock
with no bottom inset, making roughly 180pt of every scroll view permanently
unreachable. In SwiftUI: the sky ignores safe areas, every scrolling panel
receives a bottom content inset equal to player-bar + dock + bottom inset, and
no individual view sets its own top or bottom padding.

**Dynamic Type.** Every UI and mono style scales. The display face scales with
a cap — it is already 60pt and must not run off-screen at accessibility sizes.
Rows grow vertically rather than truncating; two-line titles become three.
Fully operable at the largest accessibility size, including every sheet's
action row, which should wrap rather than compress.

**Accessibility.**

- **Contrast.** Sky labels currently sit below 3:1 against black — below the
  non-text minimum, well below the 4.5:1 text minimum. The faintness does real
  aesthetic work, so split label from atmosphere: the star field and glow stay
  as faint as desired while the text layer sits at a fixed compliant luminance
  with a soft dark halo behind it. Ship a Sky contrast control.
- **Increase Contrast** raises `rule` and `edge`, drops glass transparency, and
  lifts all tertiary text to `bone2`.
- **Reduce Transparency** replaces every glass surface with an opaque
  `rgba(16,19,25,0.94)` equivalent. Already handled in the web build; keep it.
- **Reduce Motion** disables the airlock entirely, replaces sky flight with a
  cross-fade, stops nebula drift and spectrum reactivity, and cuts planet
  formation to a single dissolve.
- **VoiceOver.** Every celestial mark is an element with a real label — "Ctrl
  (Sessions), SZA, album, in R&B and Soul". The sky exposes a rotor over
  regions → constellations → stars so it is navigable without sight of it.
  The HUD is a live region. The altitude strip announces tier changes.
- **Hit targets** 44×44 minimum, including every transport control and the
  per-row overflow buttons.
- **Focus** is visible: 1pt white outline, 4pt offset.
- Full keyboard support on iPad with a hardware keyboard: space to play/pause,
  arrows to seek and change tracks.

---

## 19. Component inventory

Build these first; every screen composes from them.

| Component | Notes |
|---|---|
| `AeonScreen` | owns safe areas, the void ground, and the bottom content inset |
| `AeonGlass` | the silver-chamber material: blur + refraction + facet edges |
| `AeonBreadcrumb` | kicker / altitude strip — one component, both uses |
| `AeonButton` | three tiers: filled (one primary per screen), hairline, bare text. Destructive variant confirms by name and never sits in a button row |
| `AeonToggle` | fill-based state, not knob-position-based |
| `AeonSegment` | selection adds contrast |
| `AeonRow` | the track row — album, playlist, search, queue all use it |
| `AeonLabel` | mono caps with the contrast floor baked in |
| `AeonArtwork` | square, hairline border, offset outline, shadow, placeholder |
| `AeonSheet` | drag-dismissable, grab handle, glass body, max two deep |
| `AeonChrome` | player bar + dock, with the artwork scrim beneath the glass |
| `AeonEmptyState` | celestial mark, display-face line, optional action |
| `AeonToast` | transient, glass, never blocking |
| `AeonProgressBar` | import, storage — one component |
| `AeonSkyView` | the Metal host |
| `AeonHUD` | mono readout, live region |
| `AeonCeremony` | non-blocking announcement banner |

---

## 20. Existing assets

| Asset | Location | Note |
|---|---|---|
| `AeonNocturne-Regular.woff` | `app/fonts/` | display face, present. Needs OTF/TTF conversion for iOS |
| GUST font licence | `app/fonts/GUST-FONT-LICENSE.txt` | must ship with the font |
| LPPL 1.3c | `app/fonts/LPPL-1.3c.tex` | as above |
| Nocturne readme | `app/fonts/README-Aeon-Nocturne.txt` | provenance |
| `AeonArthemys` | **missing** | referenced 5× in the web build, no file anywhere |
| App icons | `app/icon-180.png`, `app/icon-512.png`, `ios/App/App/Assets.xcassets/AppIcon.appiconset` | |
| Splash | `ios/App/App/Assets.xcassets/Splash.imageset` | |
| World reference renders | `world-1.png`, `world-2.png` (repo root) | planet look development |
| Icon set | inline SVG in `app/index.html` (`ICO` map) | sky, note, planet and others — convert to SF Symbols or bundled vectors. **No emoji, ever.** |
| Behavioural reference | `app/index.html`, `app/interface.css` | what the app currently does |
| Native audio | `ios/App/App/Audio` | **untouched by this handoff** |

---

## 21. Non-negotiable design decisions

1. **The sky is the ground**, not a tab. Panels rise over a Sky that keeps
   rendering underneath.
2. **One mark per thing.** An album is a star everywhere it appears. Never
   invent a second mark for an object that already has one.
3. **Star coordinates are permanent.** Only charting and manual tag edits move
   a star — never an importer, rescan or migration.
4. **Planets are immutable** and point at their stars rather than holding them.
5. **Planet appearance is deterministic from a stable seed.** A restore must
   regenerate identical planets in identical positions.
6. **Square corners.** Radius zero, with the single circular transport glyph as
   the only exception.
7. **Silver glass, white type, vibrant sky** — the inherited house style, and
   the glass keeps its transparency. The fix for the artwork-contrast bug is a
   scrim beneath the glass, never an opaque bar.
8. **The accent is sampled from the playing artwork** and marks only the
   present tense.
9. **Never render a null as a token.** No `<unknown>`, no `0000`.
10. **No emoji anywhere.** No dashed borders. No numbered tabs.
11. **The existing copy is kept.** New user-facing strings get reviewed, not
    assumed.
12. **Magnitude encodes listening**, not acquisition.

---

## 22. Optional — Codex may omit

Valuable, not load-bearing. Cut freely under time pressure; none of it changes
the structure.

- The airlock overture. It is beautiful and it is also the thing between the
  user and their music. If it survives, it must stay skippable and must not
  replay after first run.
- Grain overlay and glitch effects.
- Planet `Drift` — continuous playback seeded from an era, wandering outward
  into neighbouring regions.
- Planet naming by the user.
- The planet jump list as a fast-travel menu.
- Ceremony banners for constellation formation.
- Wider-framing option in Capture.
- Recommendations card in Library.
- Activity log.
- Album merge and manual track reorder.
- iPad keyboard shortcuts beyond transport.

---

## 23. Unresolved — needs Clayton

1. **Planet interval.** The code says `PER_WORLD = 50`; Clayton has described
   it as every 20 albums. These disagree and the backfill depends on the
   answer. Also worth settling whether the interval widens as a library grows —
   at 2,000 albums, 20 produces a hundred landmarks and 50 produces forty.
2. **`AeonArthemys`.** Source the real font file, or standardise on Aeon
   Nocturne and remove the reference. Whichever it is, the licence ships with
   the binary.
3. **Display-face licensing** for App Store distribution — confirmed for the
   GUST/LPPL faces present, unknown for Arthemys until it is identified.
4. **Do EQ and Spectrum actually move into the player**, or stay in Settings?
   This spec assumes they move.
5. **Destructive confirmation copy** for Erase Everything and Delete Album.
6. **Planet naming** — the default catalogue designation format, and whether
   the user can rename.
7. **iPad as a first-class target or a stretched phone app?** This spec assumes
   first-class, which is roughly a third of the layout work.
8. **Landscape on iPhone** — supported as specified, or locked to portrait?
9. **Who is this for?** If it is Clayton and a handful of people with
   well-tagged libraries, the tagging surface shrinks and the sky work grows.
   If it is meant to survive someone's messy ten-thousand-file folder,
   Uncharted and the charting flight become the headline feature and the first
   thing a new user sees the app do.

---

## 24. Files changed by the UI rehaul

**None.** No HTML, CSS, asset or test file was modified. The rehaul was
developed as a specification and exists entirely in this document; the Capacitor
build on this branch is unchanged from `native-engine` and remains valid
behavioural reference.

The only file added by this work is this handoff.
