# Profile and player iteration, 2026-09-22

Owner reference recordings demonstrate interaction, not a replacement visual
design. This vertical change retains Aeon's typography, glyphs and square covers.

| Requirement | Implementation | Evidence |
| --- | --- | --- |
| Song actions without leaving the player | NowPlayingView reuses TrackActionMenu; existing album row menus preserved | Focused PlaybackFlowTests song-menu/playlist test |
| Translucent mini-player during navigation | PlayerBar uses material with Reduce Transparency/contrast fallback; root chrome stays reachable; AeonSheet, modal album detail and editor share controller and dismissal context | Focused sheet/tab UI test and simulator screenshot attachment |
| Real offline model selection | CorrectionCatalog.swift validates nine pinned, attributed OPRA records; ParametricControls offers exact-model search and preview | Source-record coefficient comparison; native decoding and combined-response checks |
| Device toggle feedback | Disabled without a profile or while reference bypass is active, with explanatory copy; explicit preview/apply, independent user EQ | Focused profile selection/toggle UI test |
| Preservation and rights | Original source records, OPRA logo, complete license/notices, versioned stable IDs; saved imports remain separate | Cheap catalogue comparison and existing persistence tests |
| Delivery limits | Original 600-second monotonic native watchdog and individual limits; separate 35-minute Release compile; IPA uploads first | Workflow packaging/deadline tests |

The owner's new request authorizes this pass's single native stage. The previous
cancelled-pass compile-only guard is removed explicitly; deadlines are not reset
within this pass. Native routing covers changed profile/player behavior plus
existing empty-player navigation, playlist, model and coordinator regressions.

Cheap local checks: 86 passed in 3.689 seconds before packaging. Native results
and the exact compiled source identity belong in the delivery report, not here
before execution. UI fixtures establish behavior, not physical audio fidelity.

Review: play a library track; open Now Playing, then the track's “…” and Add to
playlist; create/select a playlist. Navigate tabs, album detail, queue and playlist
sheets with the loaded mini-player; tap its artwork/title to reopen Now Playing.
Enable Reduce Transparency to check the opaque fallback. Open EQ → Device
correction & gain → Choose Profile, search your exact model, preview then Apply.
Toggle correction and compare effective preamp; user EQ settings should persist.

Scope limits: nine models, no automatic model inference or microphone calibration.
System Files/Photos/share sheets and system menus retain their native presentation.
This change does not qualify true-peak protection (existing protection is sample
peak), hardware routing, converted/encoded gaplessness, performance under load,
or physical-device planetary art/navigation acceptance. Prior unresolved audio
and Sky requirements remain unresolved; no physical-device acceptance or merge.
