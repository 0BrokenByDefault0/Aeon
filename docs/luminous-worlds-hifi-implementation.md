# Luminous worlds and audio implementation evidence

## Baseline and boundaries

Base: `codex/sky-ontology-reconstruction` at `4f2b27ed583b15ba5285cfbd279e80ff6639c276`.
This is 37 commits ahead of main, with no main-only commits. The old
`repair/sky-name-clearance-13dd0baa` branch diverged at `13dd0baa` and is not
the implementation base. Existing scratch checkouts were left untouched.
Work branch: `codex/luminous-worlds-hifi`. No merge or force push.

## Implemented in milestone A

| Requirement | Changed files | Evidence / limitation |
| --- | --- | --- |
| IPA before native validation; one 600-second stage | `scripts/validation-deadline.py`, `validation-budget.mjs`, `test-ios.mjs`, `test-targeted.mjs`, `.github/workflows/ios-ipa.yml` | Monotonic inherited deadline, owned process group TERM/KILL, three-second maximum grace, JSON outcome, per-test 600-second limit, 11-minute backup step limit. No second capture/test stage after failure or timeout. Release compile is separately bounded at 35 minutes. |
| Deadline behavior | `tests/validation-deadline.test.cjs`, CI/runner contract tests | 42 cheap contract checks passed in 4.319 seconds. Deliberately expired watchdog fixtures are test inputs, not validation-stage timeouts. |
| Stable six-family materials | `SkyModels.swift`, `SkyComposer.swift`, `SkyRepository.swift` | Optional versioned descriptor decodes legacy worlds, derives appearance from existing ID/seed, and is persisted on normal catalogue write. No rescan, new albums, or migration deletion. |
| Defined luminous worlds in existing Metal path | `SkyRenderer.swift`, `SkyShaders.metal` | Ocean/clouds, copper storm, fractured ice, charcoal fissures, inclined occluded rings, polar aurora; distinct roughness/cloud/emission/orientation parameters. Large and medium structures precede screen-size-gated fine detail. Native rendered appearance is pending. |
| Bounded scale and shared geometry | `SkyCamera.swift`, renderer, scene controller, screen | One continuous point-space projection for body taps, envelope culling and label clearance; envelope at most 55% usable width / 45% usable height. Rings/glow are decorative, not tap targets. |
| Approved navigation and naming | `SkyScreen.swift` | Existing 0.65/1.6 disclosure thresholds retained. Removed unselected planet-name candidates; full selected title remains in the details area; VoiceOver identity retained. No camera/grouping/backdrop rewrite. |
| Safe viewport | screen, scene controller, Metal view | Root readable insets feed label bounds and material-size budget; geometry changes update the viewport. Accessibility sizes reserve additional space. Camera coordinates do not change when playback chrome changes. |
| Native regressions and real capture fixtures | `PlanetModelTests.swift`, `SkyInteractionTests.swift` | Legacy decoding/material persistence, six families, smooth bounded envelopes, selected/unselected screenshots for six real Metal worlds. These tests are written, not yet executed. |

Cheap targeted Sky validation passed in 7.187 seconds. This includes script syntax,
16 runner/routing/watchdog checks and six existing world-clearance checks. These
checks do not prove Swift/Metal compilation, rendered pixels or audio fidelity.

Material lighting is calculated in linear light and encoded once for the existing
display-referred target. The scene's existing alpha blending is preserved; full
linear-light framebuffer compositing remains unresolved to avoid changing the
approved backdrop without rendered comparison. CPU/GPU and memory comparison,
matching baseline captures, visual art acceptance and physical-device acceptance
remain unverified. The existing renderer signposts remain available for profiling.

## Milestone B: not implemented by milestone A

Native DSP/model migration, parametric inspector, independent correction bank,
practical presets, attributable headphone catalogue/import, speaker profiles,
route binding, combined-response headroom, protective output stage, conversion
policy, reference-path measurements, gapless timeline evidence, queue/transport
corrections, audio-path reporting and diagnostics all remain outstanding.
Existing audio implementation and user settings are unchanged in milestone A.

## Owner review for milestone A

Zoom with nothing selected: genre, artist, album, then back. Select and clear a
reward world and check that its complete name appears only when selected. Compare
available worlds at discovery and close range. Show/hide the mini-player, rotate
where supported, and try larger text. Confirm playback and import behavior are
preserved. An unsigned IPA needs the owner's signing/install workflow.
