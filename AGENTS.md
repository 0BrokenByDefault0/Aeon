# Aeon agent instructions

`main` is authoritative. Do not merge or revive archived experiments or historical branches. Keep changes small, coherent, and on the current development line; do not refactor unrelated code.

## Start narrow

1. Search the exact symbol, error text, accessibility identifier, test name, or filename with `rg`.
2. Read only the matching file and useful line range. Use [docs/development-workflow.md](docs/development-workflow.md) as the repo map before broad inspection.
3. Reuse existing boundaries and patterns. Implement at the narrowest responsible layer.
4. Review the diff instead of rereading unchanged files. For CI failures, extract the failed test and bounded error context; do not load entire logs.
5. Do not load unrelated app areas, old plans, release notes, or archived branches unless the task explicitly depends on them.

## Required loop

Use `search -> minimal implementation -> npm run test:targeted -- --area=<area> -> npm run test:targeted:native -- --area=<area> -> fast unsigned IPA`.

Areas are `import`, `playback`, `library`, `sky`, `chrome`, `playlists`, and `settings`. Multiple `--area` flags are allowed. Native focused checks require macOS/Xcode. Run `npm run test:targeted -- --list` to inspect routing without executing it.

The fast IPA is iteration evidence only: it is gated by relevant cheap checks and one-family focused native tests, not the full regression matrix. Release approval requires the separate `Deep release validation` workflow plus the physical-device checklist in [docs/development-workflow.md](docs/development-workflow.md).

## Non-negotiable product constraints

- Never introduce emoji into app UI, source, documentation, or test output. Use named SVG icons or plain text.
- Preserve user-owned music metadata.
- Preserve the near-clear silver glass, white typography, square borders, and vibrant sky unless the user requests changes.
