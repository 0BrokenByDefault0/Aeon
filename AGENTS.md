# Aeon agent instructions

`main` is authoritative. Do not merge or revive archived experiments or historical branches. Keep changes small, coherent, and on the current development line; do not refactor unrelated code.

## Start narrow

1. Search the exact symbol, error text, accessibility identifier, test name, or filename with `rg`.
2. Read only the matching file and useful line range. Use [docs/development-workflow.md](docs/development-workflow.md) as the repo map before broad inspection.
3. Reuse existing boundaries and patterns. Implement at the narrowest responsible layer.
4. Review the diff instead of rereading unchanged files. For CI failures, extract the failed test and bounded error context; do not load entire logs.
5. Do not load unrelated app areas, old plans, release notes, or archived branches unless the task explicitly depends on them.

## Required loop

Use `search -> minimal implementation -> npm run test:targeted -- --area=<area> -> build and upload fast unsigned IPA -> npm run test:targeted:native -- --area=<area>`.

Areas are `import`, `playback`, `library`, `sky`, `chrome`, `playlists`, and `settings`. Multiple `--area` flags are allowed. Native focused checks require macOS/Xcode. Run `npm run test:targeted -- --list` to inspect routing without executing it.

Always build and upload the fast unsigned IPA before running native tests. Do not wait for simulator tests or the full workflow to finish before delivering the available artifact. Cheap checks and a successful device build remain prerequisites. Native tests run after upload, and their failures must remain visible without withholding or deleting the IPA.

The fast IPA is iteration evidence only: its embedded manifest records native validation as pending, explicitly skipped, or not required at upload time. Report subsequent native results separately; never present a pending or failed build as native-validated. Release approval requires the separate `Deep release validation` workflow plus the physical-device checklist in [docs/development-workflow.md](docs/development-workflow.md).

## Non-negotiable product constraints

- Never introduce emoji into app UI, source, documentation, or test output. Use named SVG icons or plain text.
- Preserve user-owned music metadata.
- Preserve the near-clear silver glass, white typography, square borders, and vibrant sky unless the user requests changes.

## Current UI direction — 2026-09-17

The user's orbital-control direction supersedes older stock-pill treatments. Keep the serif display, tracked mono eyebrows, quiet body type, dark ground, and restrained cream accent. Use `AeonOrbit` for cream title/ink and one 1.125-point stroke. Use literal destination names plus the shared trailing rule for page eyebrows.

Reuse `AeonSegmentedCapsule`, `AeonButtonStyle`, `AeonSegment`, and `AeonToggleStyle`; do not draw screen-specific pills. Primary actions are stroke-only at rest and fill only the center chamber on press. Selected controls fill only their active chamber. The toggle's entire labeled row must activate, with native switch accessibility semantics. Tabs have only a selected rule and brighter label, never a filled selected background. Import source cards remain unfilled rectangles.

Sky owns the empty-library primary import action and "Your sky is quiet". Library owns collection copy and a secondary import mark. Playlists keeps "No routes charted yet." Use distinct ghost-disc, collection-disc, and varied constellation marks. Pause decorative motion under Reduce Motion and in inactive scenes. Keep circular album imagery and Settings' ruled label/value rows without removing privacy disclosures.

UI review evidence must be real native captures from the reported commit. Verify fixture album counts; the `small` Sky fixture has 48 albums and is not one-album evidence. Preserve failed review artifacts, fix real interaction failures rather than weakening assertions, and publish the IPA before screenshot or other native tests.

## UI polish update — 2026-09-18

This update supersedes conflicting details in the first-pass direction above. Keep the opaque destination surfaces and inactive-Sky gating; do not reintroduce cross-screen text bleed. Library, Playlists and Settings use an H1 without a duplicate destination eyebrow; Library keeps its album count.

Use the shared `AeonEmptyState` recipe with distinct sky, collection and route motifs. Empty Library has its own centered Import action; show the header Import action only when the collection has content. Preserve the existing copy voice, including "Aeon only reads what you hand it."

Equal-option controls use identical inset oval chambers and explicit non-overlapping touch cells, with only the selected chamber filled. Toggle endpoints read OFF and ON, never quantity marks. Keep the primary action's three-chamber orbital geometry and the shared stroke weight. Import cards are unfilled rounded outlines with top-aligned icon/title stacks; fit the source sheet to measured content and allow large-text scrolling without replacing the sheet's identity.

Reserve the swash arrow for primary actions. Chevron means disclosure, plus means add/create, downward tray means choose input, upward tray means export, and circular arrow means repair/retry. Supporting text is regular-weight sans serif. Settings shows the embedded version/build/commit to distinguish signing inputs. UI work must not change the file-copy importer, folder presenter, playback engine, signing identity, or IPA-first workflow.
