# Award-and-mix plan audit

This is the living audit companion to `award-and-mix-plan.md`. It keeps
machine-checkable work in the repository and names the gates that require a
device, a native speaker, or App Store Connect access.

## Completed in the repository

- iPhone and Apple Watch are the supported app surfaces; the old DJ/Mac paths
  are excluded from the project.
- Semantic light/dark palette assets cover every foreground/background token;
  the app setting supports System, Light, and Dark.
- Dynamic Type tokens, Watch-local Dynamic Type tokens, accessibility scrubber
  actions, haptics, symbol effects, and numeric transitions are wired into the
  active UI surfaces.
- Smart transitions use the stored beat grids and phrase maps through one
  `TransitionPlanner` implementation shared by preview and playback. The
  executor cues the incoming AVPlayer item at its analyzed entry, schedules it
  against the outgoing item's host clock, applies one player-volume gain ramp,
  returns the temporary tempo change to 1.0, and applies bounded drift
  correction. Missing grids and unavailable buffering are visible downgrade
  states rather than invented confidence.
- Mix planning, schema v31, energy/embedding inputs, real waveform preview,
  phrase/Camelot explanations, two-track audition, shared preparation state,
  whole-mix preparation, apply-order error handling, and apply-order undo are
  implemented in the app path. The Listen entry point seeds from the library.
- The app catalog is now generated from SwiftUI interface literals and the
  guard requires all seven configured locales and non-empty values. Newly
  extracted values are explicitly marked `needs_review`; native-speaker
  translation review remains a release gate rather than being represented as
  completed by a catalog-count check.
- iOS/watchOS build and test runners are single-flight and sequential. The
  policy is recorded in `CLAUDE.md`, and all local xcodebuild lanes disable
  parallel testing.

## Explicit release gates

These cannot honestly be completed by source changes alone:

1. Measure five constant-tempo transition pairs on a real device and stop the
   release if median absolute alignment error exceeds 20 ms.
2. Run the iPhone/watch UI smoke and full UI regression suites manually,
   including the Build a Mix → Why → Audition → Play path.
3. Complete a VoiceOver-only device walkthrough at the release candidate.
4. Have native speakers review German, Simplified Chinese, Spanish, French,
   Japanese, and Brazilian Portuguese; then change reviewed catalog entries
   from `needs_review` to `translated`.
5. Capture and approve localized/light/dark store assets and complete App Store
   Connect metadata and submission.

The first four are release-blocking evidence, not reasons to weaken the
automated guards. The designer app icon was delivered and wired in on 2026-09-30 (A11).

## Vendored TODO triage

TODO markers in `Sources/CSQLiteVec` and `Sources/CLAMEBridge/vendor` are
upstream vendored implementation notes, not application work items. They are
excluded from the app TODO sweep and must be revisited only when upgrading the
corresponding vendored library. The one application-side historical note in
`JamendoGenreProvider` is retained as documentation of the corrected provider
tag mapping, not as an outstanding task.
