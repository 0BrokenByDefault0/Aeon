# Mini-player follow-up, 2026-09-22

The owner authorized a new bounded fix pass after build 163's timeout. Baseline:
remote `19315cf9e252693ba24d4f48e88d9f54ada74516`, local equivalent tree
`9aa012e4214e8b87eb739145eefb35473928a8a6`. Build 163 and its failed evidence remain
available; that run is not retried or reclassified as passing.

Saved native accessibility evidence shows both the covered root mini-player and
the album mini-player exposed as `aeon.player.open`. It also shows each album row
overriding its play and menu child identifiers with `aeon.album.track.<id>`. The
album ScrollView extends through the bar's frame despite the prior safe-area inset.

Changes:

- `PlayerBar.swift`: one observable presentation stack chooses the active bar;
  covered bars preserve layout while withdrawing touch and accessibility targets.
  Modal content and the player occupy separate VStack regions. All layers still
  share the original PlaybackController. Dismissal removes only its own token.
- `AeonRootView.swift`: owns the presentation state and passes it to both root and
  modal player views.
- `QueueView.swift`: explicitly carries the current player context through the
  Menu-hosted playlist/info presentation.
- `AlbumDetailView.swift`: makes the album row an accessibility container so its
  play and action buttons retain their individual identities.
- `DesignTokenTests`: checks nested ownership and both dismissal orders.
- `PlaybackFlowTests`: preserves the failed sequence, requires exactly one
  reachable player, and also exercises nested playlist, queue and profile sheets.
  No first-match fallback or removed assertion hides duplicate controls.

One focused post-IPA stage covers those two UI flows, design/presentation state
and playlist persistence. Already-passed unrelated empty-player exits are not repeated. The 600-second enclosing and individual limits and
separate bounded Release compile remain unchanged. This is a new owner-authorized
pass, not a reset of the expired stage.

Review: Now Playing → song menu → Add to playlist → create; show album → another
song's menu → Add to playlist → tap mini-player to return through both sheets;
check queue and profile sheets, then all four tabs. Check the same flow with
VoiceOver and on a signed physical build. This change does not claim physical
acceptance, true-peak qualification, gapless qualification or closure of the
earlier Sky-art requirements.


## Added owner report: “Could not prepare media”

The owner reported a file failing after Play during this authorized follow-up.
The old message hides all scheduler operation failures except tagged engine-start
errors. The affected build and source format have not yet been identified; there
is no reproduced cause, and this pass must not label the report fixed on the
strength of diagnostics or mock playback alone.

- `QueueScheduler.swift`: retain the failing access/graph/decoder/scheduling stage
  with only native domain/code, preserving cleanup and original structured errors.
- `PlaybackCoordinator.swift`: show the specific stage and useful native code in
  the player; failed playback retains paused intent.
- `DiagnosticsLog.swift`: retain these path-free codes in the existing export.
- `PlaybackCoordinatorTests`: error classification, intent and path redaction.
- `AudioEngineGraphTests`: real bundled WAV opening, decoder/player negotiation,
  scheduling and production DSP offline rendering, requiring non-silent finite
  samples and a Float32 null below −100 dBFS after 128-frame declared latency.
  Existing graph allocation and independent bell-response tests also run.

The same single native stage includes graph, scheduler, coordinator and diagnostic
unit tests. It remains bounded at 600 seconds, with no new worker or timeout reset.
No speculative file importer, DSP coefficient or media database change is made.
The reported owner's file and physical route remain unverified.
