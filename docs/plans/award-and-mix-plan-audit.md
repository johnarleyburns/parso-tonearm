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
- Smart transitions publish a plan, prepare a bounded AVPlayer item, use time
  domain pitch preservation, exact seek/preroll, audio-mix ramps, host-time
  math, bounded drift correction, and an explicit fallback path.
- Mix planning, schema v31, preview/explanations, transition preparation, and
  visible Now Playing/up-next transition state are covered by package tests.
- Localization catalogs are present for the app and every extension. The
  localization guard requires all seven configured locales, non-empty values,
  the Platterhead display name, and a ratchet against new hand-written plural
  branches.
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
automated guards. The app icon remains the documented human-designer TODO.

## Vendored TODO triage

TODO markers in `Sources/CSQLiteVec` and `Sources/CLAMEBridge/vendor` are
upstream vendored implementation notes, not application work items. They are
excluded from the app TODO sweep and must be revisited only when upgrading the
corresponding vendored library. The one application-side historical note in
`JamendoGenreProvider` is retained as documentation of the corrected provider
tag mapping, not as an outstanding task.
