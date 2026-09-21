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

## Continuation from the delivered `cc7f90e3` IPA

Current baseline is `codex/luminous-worlds-hifi` at
`cc7f90e30cd195d5ce0b20440f4cc19cd4f33476`, not either older discovery branch.
Run 35613756451 compiled and uploaded the IPA successfully. Its native stage
completed with 28 passing unit tests and six failed UI dismissal assertions;
this was an assertion failure, not a timeout. All six checked immediately
after a single tap, which waits for double-tap recognition to fail.

The continuation retains those empty-sky dismissal assertions with a three-second
predicate wait, adds an explicit CLOSE action to selected planet details,
interrupts camera flights for every direct gesture, and announces the actual
planet name to VoiceOver even when visually unselected. Selection alone still
controls visible planet names. Audio and camera disclosure thresholds are unchanged.
Cheap targeted Sky checks passed (22 tests plus syntax) in 6.251 seconds.
Replacement Release compilation and native interaction results remain pending.

Replacement `110a53e3bf88a0fa8967d16bb23bcb6b1ebaab0b` was delivered as version
5.0 build 156 (2026-09-21 15:02:00 UTC). The embedded IPA manifest matches the
compiled checkout. Run 35615806961 passed 28 unit and nine UI tests, including
all six family dismissal checks, in one 511.549-second native stage. Simulator
screenshots are retained in the native xcresult. This validates interactions,
not physical-device acceptance or art/performance approval.

## Queue / repeat vertical slice (not the completed DSP milestone)

`PlaybackModels.swift` adds a persisted queue-occurrence ID, with decoding for
older snapshots. `QueueView.swift` keys hosted rows by that identity so repeated
tracks and reordered ordinal labels do not share a row's state. Queue edits
reconcile the actual live occurrence after an EOF transition.

`QueueScheduler.swift` prepares Repeat One and Repeat All successors on the
existing A/B timeline, including wrap to the queue's first occurrence. These
normal repeat boundaries no longer depend on a coordinator stop/seek/restart.
The coordinator's recovery fallback remains in place. Tests check three-item
wrap scheduling, Repeat One source-frame zero, unchanged current schedules,
and duplicate-identity persistence. The integration test now observes each
player's frame clock independently and invokes the current item's completion,
not the newly prepared successor's callback.

Cheap playback checks passed (30 tests plus syntax) in 4.843 seconds. Swift
compilation and native tests are pending. These schedule checks are not measured
gapless PCM, conversion, true-peak, or physical-device evidence. EQ, correction,
limiting, conversion and audio-path UI work listed above remain outstanding.
The targeted router now associates these three playback test files with playback,
avoiding an unrelated all-area native run just because a regression test changed.

The collapsible Audio path readout in `EQView.swift` uses the file descriptor,
the actual EQ-node processing rate and live output descriptor. It reports EQ,
normalization and the current legacy EQ preamp, explicitly identifying headroom
as an estimate and stating that there is no validated limiter. Lossy-source bit
depth, unknown output information, DAC resolution and Bluetooth codec are not
invented. This is diagnostic visibility, not implementation of the pending DSP
bank/profile/protection requirements. No new processing is enabled by this view.

## Owner review for milestone A

Zoom with nothing selected: genre, artist, album, then back. Select and clear a
reward world and check that its complete name appears only when selected. Compare
available worlds at discovery and close range. Show/hide the mini-player, rotate
where supported, and try larger text. Confirm playback and import behavior are
preserved. An unsigned IPA needs the owner's signing/install workflow.
