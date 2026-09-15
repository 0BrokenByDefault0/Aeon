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

## One typeface, two widths

**Archivo**, variable, `wdth 62–125 / wght 100–900`, bundled at
`ios/App/App/Resources/Archivo-Variable.ttf` under the OFL.

- **Display** — `wdth 118`, `wght 600`, tracking `-0.022em`. Names of things:
  screen titles, album and playlist names, planets.
- **UI** — `wdth 100`, `wght 400–600`. Everything you operate: rows, body copy,
  buttons, settings.
- **Labels** — the UI face, uppercase, `wght 600`, tracked `+1.6`, tabular
  figures. Counts, durations, coordinates.

There is no third face. The old mono role is the UI face with tabular figures;
the old serif display face is gone. Because both widths come out of one
skeleton, a settings list reads as the same voice as the title above it — that
is the whole reason for the choice.

Swift: `AeonTheme.FontToken`. It drives the variation axes through
`kCTFontVariationAttribute` and scales with `UIFontMetrics`, so Dynamic Type
still works; if the face is ever missing it falls back to the system family at
the nearest width rather than dropping to body text.

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
