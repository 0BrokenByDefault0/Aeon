# Player layout follow-up

Owner authorized a fresh pass after build 164 timed out during simulator test
preparation (600s plus 3.419s cleanup, no completed test in the summary). Preserve
that failed evidence; do not retry or relabel it. Baseline remote 365f228efc95d1c806fec6f1dbb3038f537914b7,
local equivalent a3ba56d, tree 9197a5bdc06b66a8baca82b4c40b90e0d7a23fd5.

- AeonRootView: full Now Playing uses the safe-area viewport, without browsing
  dock/mini-player padding or a second chrome layer. Underlying catalogue/Sky
  layout reservations remain stable, so closing returns without moving the scene.
- NowPlayingView: remove the glass panel outline, size square art from available
  width and height, group metadata/seek/transport/queue in a viewport-sized primary
  section. Advanced EQ, volume and spectrum stay scroll-accessible. Large text
  and short/landscape screens may scroll rather than clip controls.
- PlayerBar: 56pt minimum body, 40pt square art, tighter text spacing, one lighter
  material surface. Modal sheets have a clear presentation background so the bar
  does not sit inside a second gray slab. Reduce Transparency/high contrast retain
  opaque material; existing 44pt transport targets remain.
- PlaybackFlowTests: full-screen/no duplicate controls, bottom viewport coverage,
  rotation, close/restoration, real captures; preserve nested playlist/queue/profile
  tests. Expectations inside full player now require no mini-player, per the owner's
  clarified requirement, and still require one inside browsing/modal surfaces.
- Targeted routing: one native invocation for changed UI, retaining the 600-second
  stage and test caps. IPA first. No native audio graph or import changes.

Review: browse album with mini-player, open Now Playing, check art/title/seek/
transport composition and full-height scroll; use song menu and queue; close to
unchanged album/position; test nested playlist sheets, rotation and larger text.
Native rendering and physical-device results are pending. The original media
preparation failure, broader DSP qualification, Sky labels and planet art remain
unresolved by this strictly presentational pass.


Owner steering during this pass explicitly removes backwards-compatibility as a
constraint. App and test targets now require iOS 26.0 for native Liquid Glass.
The mini-player uses one native regular-glass capsule with no second border or
material plate, tighter square artwork/text, and a restrained inset progress line.
Reduce Transparency/high contrast remain supported as accessibility preferences,
not legacy-OS fallbacks. The pre-16.4 sheet-background fallback is removed.
Pod dependencies keep their existing lower build minimum; this does not lower the
app's required OS. No dependency sweep is needed to link these into an iOS 26 app.
