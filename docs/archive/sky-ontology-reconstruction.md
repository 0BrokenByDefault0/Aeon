# Sky reconstruction validation

Baseline: `codex/sky-recovery-player-eq-import`, `f3fd5dbb1670e4f24086432a7cb61f6ec39fcb29`.
Corrective branch: `codex/sky-ontology-reconstruction`. No merge.

## Production grammar

- One catalogue album supplies one luminous star core. A halo is a co-located sprite, not another member.
- Artist edges connect only owned album IDs, with at least two members and a 256-world-unit edge ceiling.
- Genre seeds broad initial placement. Existing coordinates survive backfill, edits and imports; relationships and names update.
- Worlds are collection milestones, not genres or literal album systems. The visible count is `floor(currentAlbums / 15)`. Falling below a threshold removes the highest slot; surviving slots preserve identity and descriptors. A recreated slot uses its deterministic slot seed and the then-current formation context.

## Rendering and interaction

The camera is authoritative. Recognizers apply incremental deltas, pinch preserves its midpoint, and direct touch cancels flights. Navigation bounds are cached; clamping does not force the entire viewport inside small collections. Album core/halo size, artist edge detail and planet detail interpolate in Metal rather than rebuilding at enum boundaries. Native overlays project anchors without scaling typography.

Worlds use analytic spheres and persisted palettes/seeds. Surface frequency fades with pixel footprint; this avoids close-up bitmap magnification and texture generation during pinch. Background particles are deterministic noninteractive atmosphere.

## Import safety

Directory modification times do not prove file contents are unchanged. Each update enumerates cheap prefetched attributes; unchanged files bypass metadata, artwork and probing. A move requires unique stable resource identity, never size/date alone. Failed files keep their previous fingerprints and are retried. Modified audio refreshes technical properties without replacing collector-edited titles or artists. Missing files retain catalogue records; no user-owned files are deleted.

## Evidence

`AeonScreenMatrixTests.testDefinitiveSemanticReviewCaptures` records exact 0, 1, 3-same-artist, 14, 15 and 33-album fixtures plus album/artist/world focus, Library, Now Playing, EQ and contextual actions. Native tests assert counts and actionable controls; screenshots require visual inspection. The fast IPA is published before this suite and the broader focused native checks. Native results are reported separately from the IPA's pending-at-upload manifest.

The 500-known-plus-12-new import regression checks the actual metadata/artwork call log and probe counts, not duplicate counts alone. Physical-device performance, lock-screen/background playback and signing remain physical-review checks, not simulator claims.
