# Aeon skin

The current visual direction, and where each part of it lives in the app. It
supersedes §5–§7 (typography, colour, geometry) and §9 (sky presentation) of
`docs/handoffs/claude-swiftui-design-handoff.md`; everything else in that
document — the sky grammar, the screen hierarchy, the copy — still stands.

`docs/design/ui-shell.html` is the living reference. Open it, change it, and
port what survives.

## The ground is black

`#000000`, not a dark grey. On an OLED panel an empty sky is switched off, and
that is what makes a single album star read as light rather than as paint.

Everything that is not black is white at a declared opacity — `1.0` for what you
read, `0.62` for the line beneath it, `0.42`, `0.28`, `0.16`, `0.08` for
structure. No greys mixed from paper, no cream, no warm neutrals. The only
chroma in the instrument is the accent sampled from the playing artwork, and it
only ever marks the present tense: the playing star, the seek fill, the playing
row.

Swift: `AeonTheme.ColorToken`. Metal: `SkyShaders.metal`, `skyFieldFragment`.

## Ambient dust stays at the threshold

The field draws three depth layers of dust, each parallaxed by a different
fraction of the camera so panning reads as distance. They are dim on purpose —
roughly a fifth of the brightness a star carries. Dust is atmosphere; it is not
allowed to compete with the collection.

Album stars are drawn with optics dust does not have: a hard core, a wide soft
halo, four diffraction spikes, all scaled by magnitude, which encodes listening.
That difference is what lets someone tell a record from the void without a label
anywhere near it.

Swift: `SkyRenderer.rebuildSelectionBuffers`. Metal: `dustField`,
`skyStarFragment`.

## Planets are bodies, not discs

Each planet is shaded: bands generated from its own seed, a soft terminator, a
rim where light wraps the limb, an atmosphere just outside it, and — when the
era was genre-pure — a ring that passes behind the sphere and takes the planet's
shadow across it. Palette, band frequency, ring tilt and turbulence all derive
from the seed, so no two eras look alike and a restore regenerates them
identically.

Metal: `shadePlanet`. Swift: `SkyRenderer.planetInstance` passes the seed.

## Two faces, one discipline

**Clash Display Semibold** says the names of things — screen titles, album and
playlist names, planets. It is cut rather than drawn: flat terminals, tight
apertures, very little roundness, which is what keeps a title dramatic on black
instead of soft.

It is set large and tight: `56 / 46 / 42 / 34 / 26 / 28` for the screen you are
on, a statement that owns the screen, a panel header, a name inside a screen, a
name inside a row, and the wordmark — `AeonTheme.FontToken.Display`, and nothing
between those six. Tracking is `-0.038em` at every size, which is where most of
the drama comes from; Clash is drawn on a wide sidebearing and looks soft until
it is pulled in. A display line scales with Dynamic Type and then shrinks rather
than truncating, so a screen title keeps its last letters at accessibility
sizes.

**Switzer** is everything you operate: rows, body copy, buttons, settings.
Regular / Medium / Semibold / Bold. Labels are Switzer Semibold, uppercase,
tracked `+1.6`, with tabular figures for counts and durations.

Both ship from `ios/App/App/Resources/` under the ITF Free Font License, and
both are addressed by the PostScript names of static cuts rather than through a
variable font's axes. That is not a style choice: a SwiftUI `Font` built from a
`UIFont` is a fixed size and stops answering Dynamic Type, which once left the
settings storage value at 12pt under accessibility size 5.
`Font.custom(_:size:relativeTo:)` scales; the display role passes a point size
`AeonDisplayText` has already scaled with `@ScaledMetric`.

Swift: `AeonTheme.FontToken`.

## Geometry and edges

Corners are rounded on one scale — `10 / 16 / 22 / 30` (`AeonTheme.Radius`).
Nothing is square.

Edges are gradient hairlines: bright where the light lands, gone through the
middle, faintly caught again at the far side (`ColorToken.edgeHighlight`). A
pane is `2–4%` white over a blur, held together by that edge rather than by a
border drawn all the way round. Dividers fade out to nothing across their width
(`AeonDivider`).

Spacing runs `8 / 12 / 18 / 26 / 40` and nothing else. Menus are compact;
the sky is where the space goes.

## Chrome takes no space

No dock. Four glyphs at 20% white with the active one at 100%, a 36pt artwork
thumb, two lines of text, and a hairline seek fill — over a scrim, with the sky
running to the bottom edge of the screen behind them.

Swift: `AeonChrome.compactChrome`, `PlayerBar`.

## Motion

One family of curves in `AeonTheme.Motion`: controls settle at once (120ms),
chrome crossfades (240ms), panels and sheets carry weight (spring), and every
camera move in the sky uses one flight curve scaled by how far it has to travel.
Tapping a star centres it and closes in; double-tapping the void pulls back a
tier. Reduce Motion replaces flight with a cut and stops the drift.

## Still to build

- Planet formation: the 6–8s accretion ceremony at the frontier.
- Charting flight: stars lifting out of Uncharted and joining their figures.
- Spectrum coupling beyond the nebula breath already wired into the field pass —
  mids on the playing star's glow radius, highs on diffraction spikes.

## Building it

`main` carries the skin on top of the 5.0 refinement line. The design system
resolves both: every token the refined screens use is still defined, re-pointed
at the new palette, so those screens move with the skin without being edited.

An unsigned IPA comes from `.github/workflows/ios-ipa.yml`, which runs on every
push and on demand. Apple only produces iOS binaries on macOS, so the build
happens on a hosted Mac; the artifact `Aeon-5.0-unsigned-ipa` is what sideloading
tools (AltStore, SideStore, Sideloadly) expect — they sign it with your own Apple
ID on your own machine. It cannot be installed by double-clicking, and it is not
a TestFlight build.

The workflow gates the build on the web oracles in `test/`, which still describe
the legacy Capacitor shell in `app/`. That shell keeps its own visual language
for now; the skin above is the native app's.
