# Platterhead — Apple Design Award readiness + Mixes

Status: **planned 2026-09-28, owner decisions folded in 2026-09-28; not started.** One plan, one ordered commit list: C1–C3 → A1–A11 → M1–M8 → R (release last).
Mockups: [`mockups/award-and-mix-mockups.html`](mockups/award-and-mix-mockups.html). Open it in a
browser. The toolbar switches Dark/Light and Default/Accessibility text size, because both are
requirements, not options.

Supersedes (C2 moves them to `docs/plans/archive/dj/`): `dj-transition-lab-removal-plan.md`,
`dj-basic-two-deck-plan.md`, `mockups/dj-basic-two-deck-mockups.{md,html}`,
`mockups/dj-focus-deck-mockups.html`, `dj-focus-deck/`, `dj-phase-*.md`, `dj-midi-alpha.md`,
`dj-regression-suite.md`, `dj-device-test-script.md`, `dj-stems-model.md`.
Also superseded (C3 moves them to `docs/plans/archive/mac/`): `native-mac-app-plan.md`,
`macos-app-cloud-sync-plan.md`, `macos-indexing-sync-research.md`, `mockups/macos-app-mockups.html`,
`mockups/native-mac-app-mockups.html`.

---

## 0. Goal, decisions, and the honest starting point

**Goal.** Make Platterhead a credible Apple Design Award finalist. The target category is
**Innovation**: "a private music app that plans the order of your own music like a DJ would, blends
it on the beat, and tells you exactly why." **Interaction** is the secondary category, earned
through haptics, explained transitions and the audition control. Apple picks finalists itself; you
cannot enter. What we control is (a) being on the App Store, (b) being impossible to fault on
accessibility and platform fit, and (c) having one idea that is clearly new.

**Decisions already made by the owner (2026-09-28). Do not reopen them.**
- **The DJ tab and every DJ view are removed for good.** There is no flag and no hidden toggle. The
  owner is the only TestFlight user. This is the second removal (see the `lastTabKey` comments in
  `AppState.swift`: v3 removed it, v4 brought it back). It stays removed unless the owner records
  otherwise here.
- **The product's edge is Mixes:**
  - Ordering (rising BPM by default) with compatible keys and an energy curve.
  - Transitions driven by the DJ analysis: phrase-aware and beat-aligned, with a tempo match.
  - Thorough explanations: *Why this mix?* and *Why this transition?*.
  - It does what Apple Music's AutoMix doesn't: it plans the order, works on your own files and
    remote libraries, runs entirely on the device, and explains itself.
- **Platforms: iPhone and Apple Watch only.**
  - iPad support is turned off (`TARGETED_DEVICE_FAMILY "1"`).
  - The native macOS app (`TonearmMac`) and "Designed for iPhone" on Mac are removed.
  - `Package.swift` **keeps** `.macOS(.v15)`, because `swift test` runs on the macOS host and
    TonearmCore/TonearmDiscovery must still compile there. Removing it breaks the commit gate.
- **Translations ship now, made by the agent**, marked for review. The languages are Simplified
  Chinese for mainland China (`zh-Hans`), Spanish, French, German, Japanese and Brazilian
  Portuguese. Native speakers review them in TestFlight. Machine-quality text in a TestFlight build
  is acceptable; the App Store release waits for the review (R-phase).
- **App icon: the commissioned designer icon is in (A11, 2026-09-30).** The Parso family "Pt" glyph,
  platinum with a brass glint, as an Icon Composer `.icon`. Exact colours and settings are in A11.
- **Release (Phase R) runs last**, only after every other commit in this plan is done.

**Starting point.** Measured with `grep` over `Sources/` on 2026-09-28. Re-measure; don't trust
these numbers blindly.

| Area | Evidence | Why it matters to a juror |
|---|---|---|
| Dynamic Type | 528 fixed `.system(size:)` (149 in Settings, 69 in Ingest, 61 in DJ, 47 in Sources…), 0 `dynamicTypeSize`, 0 `@ScaledMetric`; text as small as 10.5 pt | Larger Text does nothing. This fails the Inclusivity category outright and counts against every other category. |
| VoiceOver | 72 `accessibilityLabel` against ~429 buttons and ~150 `Image(systemName:)`; 2 hints | Icon-only buttons read as "button". |
| Motion | 0 `accessibilityReduceMotion`; a splash of 1.5 s plus fades (`AnimatedSplashView.swift:49`) | Motion is ignored, and the splash delays content. |
| Color and appearance | `.preferredColorScheme(.dark)` in 8 places, including the app root (`TonearmApp.swift:62`); `Palette` is dark-only literals; 123 `Color.white`/`Color(hex:)` uses outside DJ | No light mode; the whole color system is hard-coded. |
| Platform fit (iOS 27) | `AdaptiveGlass.swift` claims to "prefer native glass" but only uses `.ultraThinMaterial`; 1 real `glassEffect` in the whole codebase; custom `GlassDock`/`TabBar` instead of `TabView`; Settings built from custom cards instead of `Form`; no zoom transition into Now Playing | Reads as imitating the platform rather than using it. |
| Feel | 1 haptic call in the app; 0 `symbolEffect`/`contentTransition` | The small touches that Interaction and Delight jurors notice. |
| Icon | Single flat `AppIcon-1024.png`; no Icon Composer layers, no dark, tinted or clear variants | Looks off on an iOS 27 home screen. |
| Localization | 6 localized-string uses, no `.xcstrings`, 9 hand-written plurals (`== 1 ? "" : "s"`) | English only. |
| iPad | `TARGETED_DEVICE_FAMILY "1,2"` but 0 `horizontalSizeClass` | A stretched phone layout. **Decided: iPad off (C3).** |
| Mac | A native `TonearmMac` target (`Sources/AppMac`, 86 `#if os(macOS)` branches in the app, feature, design-system and media folders), a Mac TestFlight CI job, and `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES` | A second surface held to the same bar. **Decided: remove (C3).** |
| Focus | Player + 11 providers + two-deck DJ + stems + a 988-line Settings | You can't say what the app is in one sentence. |
| Hygiene | README still says "Tonearm" and "Transition Lab"; 33 `print(`; 34 TODO/FIXME | Visible in press and review. |

Strengths to protect: the privacy stance (no account, no telemetry), on-device semantic search, the
no-magic background rule in CLAUDE.md, Reduce Transparency already handled in
`GlassSurface`/`AdaptiveGlass`, and the ecosystem reach (Watch, widgets, controls, Siri).

---

## 1. Ground rules for every commit (read `CLAUDE.md` first)

- Work on `main`, one commit per task below, and ask before `git push`. Never use `--no-verify`.
- Swift 6 strict concurrency, no new warnings. Run `rm -rf .build` before trusting `swift test`.
- `Sources/Features/**` and `Sources/App/**` are Xcode-only, so `swift test` doesn't compile them.
  Every commit that touches them must also pass:
  ```sh
  xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
  xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
    -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
  ```
  Never pass `-sdk iphonesimulator`. Regenerate with `make project` when files are added or removed;
  never hand-edit `project.pbxproj`. Run `make ci-guards` before committing.
- **Put logic where tests can reach it.**
  - Pure value types go in `Sources/Domain/…` (TonearmCore, which has no `ParsoAudioAnalysis`).
  - Analysis and planning logic goes in `Sources/Discovery/…` (TonearmDiscovery, which has
    `ParsoAudioAnalysis` and `Camelot`).
  - Views only render.
- **No-magic rule (CLAUDE.md).** Every automatic step ships with its status surface and its
  stop/retry control in the same commit.
- **The product name is "Platterhead"** in every user-facing string. The CI guard enforces it.
- **The design bar** applies to every line of UI you touch or add from A1 on. Reviewers reject
  commits that miss it:
  1. Text uses `Typography` tokens (A3), never `.system(size:)`. Fixed dimensions next to text use
     `@ScaledMetric`. Lay out with `ViewThatFits` or a vertical fallback at accessibility sizes.
  2. Colors come only from `Palette` semantic tokens (A2). No `Color.white`, `Color.black` or
     `Color(hex:)` in feature code.
  3. Every interactive element has a VoiceOver label (and a value when it has state). Group
     compound rows with `.accessibilityElement(children: .combine)`. Charts provide
     `accessibilityChartDescriptor`.
  4. Animations check `accessibilityReduceMotion`; use `Motion.standard` (A4). Never carry meaning
     through color alone.
  5. All strings go through `String(localized:)` in `Resources/Localizable.xcstrings`, with plural
     variants from the catalog. **From A9 on, every commit that adds or changes a user-facing
     string also adds its translation in all six languages** (`zh-Hans`, `es`, `fr`, `de`, `ja`,
     `pt-BR`) with state `needs_review`, following the glossary in `docs/l10n/GLOSSARY.md`. Check
     the layout in German (longest) and Chinese/Japanese (line breaking) as well as English.
  6. Use system components where one exists: `TabView`, `List`, `Form`, sheet detents, `Menu`,
     `.glassEffect`, `.buttonStyle(.glass)`.
  7. Add `.sensoryFeedback` wherever state changes because of a touch.
- **Ratchet guards (A1).** `check-ci-guards.sh` fails if the count of `.system(size:`,
  `preferredColorScheme(`, `Color.white`/`Color.black`/`Color(hex:` (outside `DesignSystem/`), or
  `print(` in `Sources/` rises above the number recorded in `scripts/design-ratchet.txt`. Every
  commit that lowers a count also lowers the recorded number. The goal is zero, except the entries
  allowlisted in that file with a reason.

---

## 2. What exists today (verified 2026-09-28; re-verify before acting)

| Concern | Where | Fate |
|---|---|---|
| Full-track analysis (grid, downbeats, sections, key, waveform, loudness) | `Sources/Features/DJ/Model/DJAudioBacker.swift:24` `prepare(…)` → `TrackAnalyzer().analyze(buffer)`; mapping in `DJTrackPrepPayload+Analysis.swift` | **Move** into TonearmDiscovery (C1) |
| Analysis cache | `dj_track_prep` table, `DJTrackPrep`/`DJTrackPrepPayload` (`Sources/Data/DJRecords.swift`, `Sources/Domain/DJTrackPrepPayload.swift`, `Sources/Data/LibraryStore+DJ.swift`) | **Keep.** Don't rename the table or CloudKit record type. Hot-cue/loop columns go dormant. |
| Sync of prep | `Sources/Sync/RecordMapping+DJ.swift`, `CloudSyncEngine.swift` | **Keep** unchanged |
| Library-wide BPM/key/energy (a mid-track window, no grid) | `Sources/Discovery/BoundedIndexWorker.swift:381` → `discovery_track_analysis` | **Keep.** The order planner uses it. |
| My Music BPM/key badges | `AppState.musicalInfo: [Int64: DJLoadTrackInfo]`, `MyMusicFilter`, `Components.swift:203`, `LibraryView.swift:154` | **Keep** |
| Camelot and BPM gate | `Sources/Discovery/MusicalMatchPolicy.swift` | **Keep**, reuse |
| Playable URL | `AppState+Downloads.swift:18` `djPlayableURL(for:)` | Keep; rename to `analysisPlayableURL` (C2) |
| Crossfade | `Sources/Audio/AudioPlayer+Crossfade.swift`, `CrossfadeCurve.swift` | Keep as the fallback (M5) |
| Keep Playing | `KeepPlayingPicker.swift`, `AudioPlayer+KeepPlaying.swift` | Keep |
| DJ UI and deck engine | `Sources/Features/DJ/**` | **Delete** (C2) |
| DJ-only policies | `Sources/Domain/DJ{CoachPolicy,GridLayout,LayoutSwitchPolicy,PerformPages,RecordingStoragePolicy,SurfaceMap,SyncAvailabilityPolicy,TempoNudgePolicy,WaveformTouchPolicy}.swift` | **Delete** (C2). `DJLoadSourcePolicy` moves with the analyzer if C1 needs it. |
| Crate | `PlaylistsView.swift:69,124`, `AppState.setPlaylistInCrate`, `LibraryStore+Playlists.swift:39` | Delete the UI and API. Leave the `isInCrate` column. |
| Chrome | `Features/Chrome/GlassDock.swift`, `AdaptiveGlass.swift`, `Features/Components.swift` `TabBar`, `DesignSystem/GlassSurface.swift` | Replaced in A5 |
| Colors | `DesignSystem/Palette.swift` (dark-only literals) | Becomes semantic and dynamic in A2 |
| Splash | `Features/Onboarding/AnimatedSplashView.swift`, `RootView.swift` `showSplash` | Removed in A4 |
| Schema head | `Sources/Data/Schema.swift` `migrationOrder` ends at `"v30"` | M6 adds `v31` |

---

## 3. Commit list, in order

The order is **C1 → C2 → C3 → A1 … A11 → M1 … M8 → R**:
1. Remove what's going first, so nothing gets polished that will be deleted.
2. Lay the design and localization foundations, so the Mix UI is compliant and translated from the
   start.
3. Build the Mix engine, then its UI.
4. **Release (R) is last and starts only when every earlier commit is done.**

**Track M-engine (M1–M5) is pure code with disjoint files, so it can run in parallel with
A5–A11.** M6–M8 must wait for A5 (chrome) and A9 (catalog and glossary). The only expected
collision is `project.pbxproj`, which is resolved by `make project`.

### Phase F — Focus

**C1 `refactor(analysis): move full-track grid analysis out of the DJ feature`**
A pure move; the DJ tab still works afterwards.
- New `Sources/Discovery/Transition/TrackGridAnalyzer.swift` holds the decode-and-analyze half of
  `DJAudioBacker.prepare`. API:
  `static func analyze(url:codec:cached:cachedFrameCount:) throws -> (payload: DJTrackPrepPayload, frameCount: Int64, usedCached: Bool)`.
  Handle bookmark access as in `DJPerformanceModel+Loading.swift:154-176`.
- Move the `TrackAnalysis` ↔ payload mapping (`DJTrackPrepPayload+Analysis.swift`) beside it.
- Point the DJ deck at the moved code.
- Test (`Tests/DiscoveryTests/TrackGridAnalyzerTests.swift`), on a `Tests/Fixtures` audio file:
  BPM, beat and downbeat counts, non-empty sections, and a payload round-trip.

**C2 `feat!: remove the DJ tab and all DJ views`**
- Delete `Sources/Features/DJ/` (including `Model/`) and the DJ-only policies. Delete their tests
  (`DJFocusPolicyTests`, `DJGridLayoutTests`, `DJLoadSourcePolicyTests` unless the policy moved,
  `DJSyncAvailabilityPolicyTests`, `DJTempoNudgePolicyTests`). Keep `DJTrackPrepStoreTests` and
  `RecordMappingTests`.
- `AppState`:
  - Remove `AppTab.dj`, `djPerformanceModel` and `isPerformanceSurfaceFullScreen`.
  - Set `lastTabKey = "lastActiveTab.v5"` with the comment "v5: DJ removed for good
    (award-and-mix-plan.md); four tabs → three".
- Remove DJ routing from `RootView`/`MacRootView`, and `DJMiniPlayer`/`hasDJTrack` from `GlassDock`.
- `SettingsView`: remove the DJ card and its `@AppStorage` keys. Rename "DJ track preparation" to
  **"Transition analysis"** ("Beat grids and phrase maps used to plan transitions. Rebuilt when
  needed."), keeping its size figures and its Clear action.
- Remove the Crate UI and API. Rename `djPlayableURL` → `analysisPlayableURL` and
  `DJPlayableAssetError` → `AnalysisAssetError`.
- Tooling:
  - Remove the DJ smoke lane (`UITests/TonearmSmokeUITests.swift:66-76`) and any four-tab assertion.
  - Remove the `djmix`/`djlive`/`djhw` Makefile lanes.
  - Delete `scripts/ui-regression/{verify-mix,test-verify-mix,make-dj-fixture-media}.py` and their
    references in `run-ui-regression.sh`.
  - Set the `SiriIntentsExtension/IntentHandler.swift:3` header to "Platterhead".
- Move the superseded docs to `docs/plans/archive/dj/`. In the README, remove DJ and Transition Lab
  and add a one-line "Mixes" placeholder.
- **Done when:**
  - `grep -rnE 'DJ[A-Z]|djPerformance|\.dj\b|Transition Lab|Crate' Sources Tests UITests WidgetsExtension WatchApp SiriIntentsExtension`
    returns only the kept items (`DJTrackPrep*`, `DJLoadTrackInfo`, `DJLoadTrackFilter`,
    `DJKeyFormatter`, `DJMarkings`/`DJHotLoop`/`DJStoredCue`, `LibraryStore+DJ`, `RecordMapping+DJ`,
    and `DJTrackRow` if still used).
  - Builds, tests and guards pass.
  - The app shows three tabs, and a stored `lastActiveTab.v4 = dj` opens Listen.

**C3 `feat!: iPhone and Apple Watch only — remove iPad and the macOS app`**
- `project.yml`:
  - Set `TARGETED_DEVICE_FAMILY: "1"` for the app, `TonearmShareExtension`,
    `TonearmWidgetsExtension` and `TonearmSiriIntents`. Leave the Watch targets at `4`.
  - Set `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: "NO"` and `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: "NO"`.
  - Delete the `TonearmMac` target and scheme, and the `AppMac/**` exclusion comment.
  - Replace the Catalyst/Mac history comment (around line 193) with one line: "iPhone + Watch only
    (award-and-mix-plan.md C3)."
- Info.plists: remove the iPad-only keys (`UISupportedInterfaceOrientations~ipad`, and any
  `~ipad` variants) from the app and its extensions.
- Delete `Sources/AppMac/`, `Sources/App/MacPlaybackBridge.swift` and `ExportOptions-Mac.plist`.
  Delete every `#if os(macOS)` / `canImport(AppKit)` branch in `Sources/App`, `Sources/Features`,
  `Sources/DesignSystem` and `Sources/Media`, keeping the iOS branch. **Leave the conditionals in
  TonearmCore/TonearmDiscovery sources alone, and keep `.macOS(.v15)` in `Package.swift`**: the
  `swift test` host is macOS (see §0).
- `PlaybackPlatformBridge`: if the protocol only existed to abstract Mac and iOS, inline the iOS
  implementation. Otherwise leave it.
- `Resources/Assets.xcassets/AppIcon.appiconset`: remove the `mac` idiom entries and the
  `AppIcon-mac-*.png` files. The Watch catalog stays untouched.
- `.github/workflows/ios.yml`: delete the `testflight-build-mac` job and its Mac-only secret
  checks. Delete Mac branches in `Makefile` and `scripts/` if any exist.
- Move the Mac docs listed at the top of this file to `docs/plans/archive/mac/`. Remove iPad and Mac
  from the README roadmap.
- **Done when:**
  - `grep -rnE 'os\(macOS\)|AppKit|NSApplication|TonearmMac' Sources/App Sources/Features Sources/DesignSystem Sources/Media project.yml .github`
    is empty.
  - `swift test` passes (proving the host build still works), both xcodebuild commands pass, and
    `make ci-guards` passes.
  - `bash scripts/verify-watch-icon-catalog.sh` passes.
  - Installing on an iPad simulator shows the app as an iPhone app, in the compatibility frame.

### Phase A — Design foundations (award)

**A1 `chore(ci): design ratchet guards`**
- Add `scripts/design-ratchet.txt` with the current counts from §1 (measured after C2), plus an
  allowlist with reasons.
- Add a section to `check-ci-guards.sh` that fails when any count rises, and prints the offending
  files and the new count.
- A test in the guard script checks that an allowlisted line needs a reason.

**A2 `feat(design): semantic, dynamic Palette; drop forced dark mode`**
- `Palette` becomes semantic tokens, each defined for light and dark in the asset catalog
  (`Resources/Assets.xcassets/Palette/*.colorset`):
  - `background`, `surface`, `surfaceRaised`
  - `ink`, `inkSecondary`, `inkTertiary`
  - `hairline`
  - `accent` (brass, with a light variant that meets AA on white, about `#9A6420`)
  - `accentOnFill`, `success`, `danger`
- Keep the old names as deprecated aliases for one commit series, and delete them in A10.
- Check contrast: each ink token must reach ≥ 4.5:1 on `background` and `surface` in both
  appearances. Keep the AA comment style already in `Palette.swift`.
- Remove all 8 `.preferredColorScheme(.dark)`.
- Add **Settings › Appearance**: System / Light / Dark, applied at the root. **System** is the
  default.
- Replace `Color.white`/`Color.black`/`Color(hex:)` in `DesignSystem/` and `Features/Chrome/` with
  tokens. The rest of the app follows per area in A7.
- Also: the `GenrePickerView.swift` color literals (8) move into `Palette.genre(_:)`.

**A3 `feat(design): Typography tokens`**
- `DesignSystem/Typography.swift` maps the app's roles to Dynamic Type text styles, using `.weight`
  and `.design` where the brand needs it:
  - `display` → `.largeTitle.weight(.heavy)`
  - `title` → `.title2.weight(.bold)`
  - `headline` → `.headline`
  - `body` → `.body`
  - `callout` → `.callout`
  - `caption` → `.caption`
  - `mono` → `.caption.monospacedDigit()` for BPM, key and time
- Tabular figures for all numbers.
- Migrate `DesignSystem/` and `Features/Chrome` in this commit. The rest follows in A7.
- `@ScaledMetric` helpers: `Metrics.artworkSmall`, `rowHeight`, `chipHeight`.

**A4 `feat(design): motion tokens, Reduce Motion, remove the splash`**
- `DesignSystem/Motion.swift`: `Motion.standard`, `Motion.emphasized`, and a
  `.motion(_:value:)` modifier that becomes a cross-fade or no animation under Reduce Motion.
- Replace all 13 `withAnimation`/`.animation(` call sites.
- **Delete `AnimatedSplashView`** and the `showSplash` path in `RootView`. The static
  `UILaunchScreen` is the only launch surface. Remove `splash_screen.jpg` from the bundle if nothing
  else uses it.

**A5 `feat(chrome): native TabView, bottom accessory, real Liquid Glass`**
- Replace `GlassDock` and the custom `TabBar` with a system `TabView` (Listen, My Music, Settings)
  and the `.tabViewBottomAccessory` mini-player. Minimize on scroll with
  `.tabBarMinimizeBehavior(.onScrollDown)`.
- The watch `TransferPill` moves into the accessory as a secondary line when active. Background and
  network-skip banners stay as they are, with Motion tokens.
- `AdaptiveGlass` uses `.glassEffect(.regular, in: .rect(cornerRadius:))` inside
  `GlassEffectContainer` where elements sit side by side. Keep the Reduce Transparency fallback, and
  delete the misleading comment.
- Now Playing opens with `.navigationTransition(.zoom(sourceID:in:))` from the accessory artwork
  (`matchedTransitionSource`).
- The smoke UI test still finds the tabs by label. Update identifiers if needed.

**A6 `feat(settings): rebuild Settings as a Form`**
Target: under 400 lines per file, split by section.
- **Top level:** Playback (crossfade, Smart transitions from M4, EQ), Music Libraries, Appearance,
  iCloud Sync, Apple Watch, Privacy, Support Development, About.
- **Advanced**, pushed as its own `Form`: prefetch depth, cache limit and clear, Jamendo key, Keep
  Playing batch size, Sound Index, Transition analysis storage, custom-artwork storage, Tools.
- Every row uses standard `LabeledContent`, `Toggle`, `Picker` and `Stepper`, so Dynamic Type and
  VoiceOver come for free. Destructive actions use `confirmationDialog` with a `role: .destructive`
  button.

**A7 `feat(a11y): type, color, and VoiceOver sweep — <area>`** (one commit per area, in this order)
Areas: Now Playing and Up Next → Listen → My Music and Library → Playlists → Sources and Ingest →
Discovery → Onboarding → Widgets, Share and Siri extension UI.

For each area:
- Replace every `.system(size:)` and color literal with tokens.
- Label every icon-only button, and combine rows.
- Add `.accessibilityValue` to stateful controls: the scrubber (with `accessibilityAdjustableAction`
  to seek ±15 s), volume and toggles.
- Check the layout at AX5.
- Lower the ratchet numbers.
- Do a manual VoiceOver pass on the simulator, and write the checklist into the commit body.

**A8 `feat(feel): haptics and symbol effects`**
- Add `.sensoryFeedback`:
  - `.selection` on tab and picker changes.
  - `.impact(weight: .light)` on play and pause.
  - `.success` on add-to-playlist and favorite.
  - `.warning` on destructive confirms.
- `.symbolEffect(.bounce)` on favorite.
- `.contentTransition(.symbolEffect(.replace))` on play/pause.
- `.contentTransition(.numericText())` on counters, cache sizes and track counts.
- All of it respects Reduce Motion (A4).

**A9 `feat(l10n): String Catalog, extraction, and first-pass translations`**
This may be split into A9a (extraction) and A9b (translations) if one commit is too large. Both
must land before M6.

- **Extraction.**
  - Create `Resources/Localizable.xcstrings`, plus `InfoPlist.xcstrings` for permission prompts and
    the display name.
  - Give each extension (widgets, share, Siri, Watch app) its own catalog.
  - Convert every user-facing literal to `String(localized:)`/`LocalizedStringKey`, with a
    `comment:` wherever the context isn't obvious ("Button: starts the mix").
  - Replace the 9 hand-written plurals with catalog plural variants.
  - Add a guard for new hand-written plurals.
  - Set `knownRegions` in `project.yml` to `en, zh-Hans, es, fr, de, ja, pt-BR`, with
    `developmentRegion: en`.
- **Glossary first.** Write `docs/l10n/GLOSSARY.md` before translating.
  - **Never translated:** Platterhead, BPM, Camelot key codes (8A), iCloud, Apple Watch, Siri,
    CarPlay, and provider names (Dropbox, Jellyfin…).
  - **Chosen once per language:** Mix, Blend, Phrase fade, Plain fade, Transition, Energy, Shape,
    Rising BPM, Wind down, "Why this mix?".
  - For `zh-Hans`, use mainland conventions: Simplified characters, full-width punctuation, and
    mainland music terms (for example 混音 for Mix, 节拍 for beat). Record every choice in the
    glossary so later commits stay consistent.
- **Translations.**
  - The agent translates every string into the six languages, following the glossary. Use the
    formal register where a language has one: `Sie` in German, `vous` in French, です/ます in
    Japanese.
  - Every entry is marked `needs_review` in the catalog, so the reviewer's progress is visible in
    Xcode.
  - Keep format specifiers and plural categories correct per language: Chinese and Japanese use
    only `other`, and `pt-BR` needs `one`/`other`.
- **Build.** Translations ship in the next TestFlight build. Add a DEBUG-only Settings › About ›
  "Language" row that opens the system per-app language setting, so testers can switch quickly.
- **Reviewer kit** (`docs/l10n/REVIEW.md`):
  - How to switch the app language on iPhone.
  - Which screens to visit.
  - How to report a fix (screenshot + the English source + a suggested wording).
  - A TestFlight "What to Test" paragraph per language, in that language.
- **Tests:**
  - Every key has a value in all 7 languages.
  - No format-specifier mismatch between variants.
  - No untranslated glossary term appears where it should be translated.
  - The display name is "Platterhead" in every language.
- **Manual check:** screenshots of Listen, Settings and Now Playing in `de`, `zh-Hans` and `ja` at
  the default and AX text sizes, attached to the commit body as paths under
  `build/l10n-screens/`. The files themselves are not committed.

**A11 `feat(brand): designer app icon (Icon Composer)`** — **designer icon delivered and wired 2026-09-30 (uncommitted).**

The human-designer TODO is closed. One designer (with input from Claude) drew all three Parso apps as a family of periodic-table element
symbols: Voxglass = **V**, Platterhead = **Pt** (Platinum), Cladiron = **Fe**. The three share one grid, one
letterform family and one layer recipe; only the letterform and metal colour differ. The designer's package is
`parso-icons-v1.0`; Platterhead's parts are in `design/icon/` (`FAMILY_README.md` is the full spec,
`style-guide.pdf` the construction and palette).

- **Glyph:** a custom-drawn "Pt" and nothing else. No tile, no "78", no name or mass (the atomic number falls below
  2 px at 58 px). The P bowl is a squircle like a platter seen edge-on; the gradient ends in a thin brass band, the
  warm glint on cool metal.
- **Layers:** document fill (background gradient) + one glyph layer (`glyph.svg`). No accent layer.
- **Metrics (1024 canvas):** cap height 432 px (cap top 288, baseline 720), x-height 324, stem 90.7 px,
  superellipse curves n = 3.0, corners convex 10 / concave 8 px, ink radius 362 px inside the 380 px watchOS safe
  circle.
- **Worst greyscale contrast (Tinted):** 6.91 : 1.

Exact colours (authored in Display P3; sRGB is the clipped conversion for anything outside Icon Composer):

| Use | Stop | Name | Display P3 | sRGB |
|---|---|---|---|---|
| Background · Default | 0.00 | `pt-bg-top` | `0.1176 0.1216 0.1373` | `#1E1F23` |
| Background · Default | 1.00 | `pt-bg-bottom` | `0.0353 0.0353 0.0431` | `#09090B` |
| Background · Dark | 0.00 | `pt-bg-top-dark` | `0.0667 0.0667 0.0784` | `#111114` |
| Background · Dark | 1.00 | `pt-bg-bottom-dark` | `0.0118 0.0118 0.0157` | `#030304` |
| Glyph | 0.00 | `pt-white` | `0.9725 0.9686 0.9529` | `#F8F7F3` |
| Glyph | 0.62 | `pt-platinum` | `0.7922 0.8039 0.8157` | `#C9CDD0` |
| Glyph | 0.84 | `pt-steel` | `0.6902 0.7020 0.7176` | `#AFB3B7` |
| Glyph | 1.00 | `pt-brass` | `0.7529 0.5765 0.3451` | `#C8914D` |

Icon Composer settings: top-to-bottom linear-gradient fill (Default and Dark as above); group "Glyph" with Liquid
Glass on, specular on, blur off, translucency off, shadow layer-colour 45 %; Tinted glyph fill "Automatic"; Clear
uses the system default; platforms: squares shared + watchOS circle.

What was done:
- `Resources/AppIcon.icon` added; the `Resources` source path picks it up (XcodeGen writes
  `lastKnownFileType = wrapper.icon` in the app's Resources phase). `actool` compiles it for iOS and watchOS
  without warnings.
- `Resources/Assets.xcassets/AppIcon.appiconset` deleted (two icons named `AppIcon` would clash).
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` is unchanged.
- The agent-made art (`Resources/IconSource/platterhead-icon.svg`) and `scripts/render-app-icon.sh` are removed;
  `scripts/make_icon.py` is marked superseded.
- Watch: `TonearmWatch` takes `AppIcon` from the same `Resources/AppIcon.icon` (its watchOS circle, the 1088 Icon
  Composer canvas), listed in the Watch sources in `project.yml`. The 11-PNG
  `WatchApp/Assets.xcassets/AppIcon.appiconset` is deleted. `scripts/verify-watch-icon-catalog.sh` and
  `WatchAppIconCatalogTests` now fail if that appiconset returns, and require watchOS `actool` to write
  `CFBundleIconName = AppIcon` from the `.icon`. CLAUDE.md's Watch icon section is updated to match.
- Icon Composer: the `.icon` was opened, all six appearances tuned, and re-saved; Tinted and 1088 watchOS PNGs were
  exported from Icon Composer (`design/icon/png/`).

Still to do (owner):
- [ ] On device: "Pt" reads at 29 pt (Settings row) and in Spotlight; the Watch app grid shows the new icon.

**A10 `chore: hygiene`**
- Delete the deprecated `Palette` aliases.
- Change `print(` → `Logger` (subsystem per area, `.debug` for noise).
- Triage the 34 TODO/FIXME: fix, turn into a plan item, or delete.
- README: the product name is Platterhead throughout (Tonearm only as the codename, in a note), and
  describe what the app is in one sentence.

### Phase M — Mixes (engine M1–M5 can run in parallel with A5–A11; M6–M8 need A5 and A9)

**M1 `feat(mix): mix and transition value types`**
Put these in `Sources/Domain/Mix/`. Everything is `Codable, Sendable, Equatable`. **Reasons are
structured data, never prose.**

```swift
enum MixShape { case risingBPM /*default*/, steady, warmUpPeakCoolDown, windDown }
struct MixCandidate { trackID; bpm: Double?; camelot: String?; energy: Double?; artist: String?;
                      albumID: Int64?; duration: Double; embedding: [Float]? }
struct MixRequest { candidates; shape; targetDuration: TimeInterval?; lockedFirst: Int64?;
                    locks: [Int64: Int]; seed: UInt64 }
struct MixPlan { steps: [MixStep]; excluded: [MixExclusion]; summary: MixSummary; request }
struct MixStep { trackID; position; effectiveBPM: Double; tempoRelation /*.same,.halfTime,.doubleTime*/;
                 reasons: [PlacementReason]; edgeIn: EdgeScore?; runnersUp: [RunnerUp] /*≤2*/ }
struct EdgeScore { key: KeyRelation; bpmDeltaPct; energyDelta?; similarity?; shapeDeviation;
                   total; flags: [EdgeFlag] }
enum KeyRelation { case same, adjacentUp, adjacentDown, relative, energyBoost, clash(steps: Int), unknown }
enum EdgeFlag { case againstShape, tempoJump, keyClash, sameArtistBackToBack, unavoidable(UnavoidableReason) }
enum PlacementReason { case lowestBPMStart, followsShape, bestKeyNeighbor, closestTempo,
                       energyFitsCurve, lockedByUser, onlyRemainingOption, soundsSimilar }
struct RunnerUp { trackID; total; lostBecause: [EdgeFlag] ; keyRelation; bpmDeltaPct }
struct MixExclusion { trackID; reason: .notAnalyzed(missing:) | .overTargetLength | .duplicate | .unplayable }
struct MixSummary { bpmRange; harmonicEdges; totalEdges; tempoJumps; againstShape; duration;
                    weakestEdges: [Int] }
enum TransitionStyle { case gapless, beatmatchedBlend, phraseFade, plainCrossfade }
struct TransitionPlan { fromTrackID; toTrackID; style; exitTime; entryTime; overlapBeats?; overlapSeconds;
                        blendRate /*1 = none*/; rateRampBeats?; gainMatchDB?; keyRelation; bpmDeltaPct?;
                        confidence; reasons: [TransitionReason]; downgradedFrom: TransitionStyle? }
enum TransitionReason { case outgoingOutroPhrase(bar:beats:), incomingIntroPhrase(beats:),
    lastPhraseBoundary(bar:), skippedLeadingSilence(seconds:), tempoMatched(pct:),
    tempoReturnsOverBeats(Int), keyCompatible(KeyRelation), keyClashShortOverlap,
    tempoTooFar(pct:), lowTempoConfidence(Double), variableTempo, gridNotReady(GridPrepState),
    notBuffered, sameAlbumGapless, loudnessMatched(dB:), userChosePlainFade }
enum GridPrepState { case ready, queued, downloading(Double), analyzing(Double), waitingForNetwork,
                     waitingForWiFi, failed(String), cancelled }
```
Test: a Codable round-trip for each type.

**M2 `feat(mix): order planner`**
`Sources/Discovery/Mix/MixPlanner.swift`, `plan(_:) -> MixPlan`. Pure, and deterministic for a given
seed.

1. **Exclusions.** A missing BPM or key becomes `.notAnalyzed`, which is shown and never silently
   dropped. A `targetDuration` trims the highest-cost tracks, each recorded as `.overTargetLength`.
2. **Effective BPM.** Compare against the neighbour as b, 2b or b/2, take the closest, and record
   half- or double-time.
3. **Shape target** from the pool's BPM quantiles (energy follows the same shape):
   - risingBPM: p5→p95, monotonic.
   - steady: the median.
   - warmUpPeakCoolDown: rises to p95 at 70%, then falls to p50.
   - windDown: p95→p5.
4. **Edge cost.** Weights live in one place, and a test pins their order.
   - key: same 0, adjacent or relative 1, energy boost 2.5, otherwise 6.
   - tempo: |Δ%| × 10, tripled when going against the shape. More than 8% adds `tempoJump`.
   - energy: deviation from the shape's expected Δ.
   - similarity: (1 − cos) × 2 when both tracks have embeddings.
   - same artist back to back: +3.
   - shape deviation: |bpm − target| / target × 10.
5. **Solve.** Start from the locked first track, or else the cheapest start (for rising BPM that's
   the lowest BPM, recorded as `lowestBPMStart`). Build with a greedy nearest-neighbour pass, then
   improve with 2-opt and or-opt under a fixed iteration budget, keeping locks fixed. Target under
   150 ms for 200 tracks on device; the test asserts under 1 s for 500 in CI.
6. **Explain.**
   - Per step: the dominant reasons (the two biggest savings compared with the average
     alternative), `edgeIn`, and up to 2 runners-up with the flag that made each lose.
   - When an edge couldn't be avoided, mark it `unavoidable(reason)` (for example "only 2 tracks
     above 124 BPM").
   - Build the summary.

Tests (synthetic pools):
- The shape is respected where the pool allows.
- A known harmonic path is found.
- Locks are respected.
- The same seed gives the same plan.
- Half-time detection works.
- Exclusions carry the right reasons.
- `unavoidable` appears on a pool with a forced jump.
- The performance bound holds.
- Runners-up are valid.

**M3 `feat(mix): transition planner`**
`Sources/Discovery/Mix/TransitionPlanner.swift`,
`plan(from: DJTrackPrepPayload?, to: DJTrackPrepPayload?, context) -> TransitionPlan`. Rules, in
order:

1. **Gapless album** (reuse `CrossfadeCurve.suppressesForGaplessAlbum`) → `.gapless`.
2. **User override** → `.plainCrossfade` with `userChosePlainFade`.
3. **A payload is missing** → `.plainCrossfade` with `gridNotReady(state)`.
4. **Beat-matched blend.** Requires tempo confidence ≥ 0.6 on both tracks, both constant tempo, and
   an effective BPM ratio within ±8%. Then:
   - **Exit:** the start of the last `outro`, or else the last 32-beat downbeat boundary at least
     16 beats before the end.
   - **Entry:** the first downbeat after leading silence (waveform RMS below −50 dBFS), with
     `skippedLeadingSilence` when the skip is over 0.5 s.
   - **Overlap:** min(outro, intro), snapped to 8, 16 or 32 beats, capped at 32 beats and 30 s.
   - **Tempo:** `blendRate = outBPM/inBPM`, then `rateRampBeats = 16` back to 1.0.
   - **Key clash:** a 4-beat overlap and `keyClashShortOverlap`.
   - **Gain:** `gainMatchDB` from the integrated-LUFS difference.
5. **Otherwise, when both grids exist:** `.phraseFade`. Exit on a phrase boundary, with an
   equal-power fade of min(8 beats, 8 s) and no rate change. The reason is `tempoTooFar`,
   `lowTempoConfidence` or `variableTempo`.

Tests cover every branch, snapping, caps, the silence skip, half-time, and that `downgradedFrom`
is set whenever a better style was blocked.

**M4 `feat(mix): transition grid prep, with status and controls`**
- `TransitionPrepService`: `@MainActor` state and a detached worker. Its window is the current
  track plus the next 2.
  - It resolves each URL with `analysisPlayableURL`, runs `TrackGridAnalyzer`, and saves with
    `saveDJAnalysis`.
  - One track at a time; skip a track whose `algorithmID`/`version` already matches.
  - Respect Wi-Fi-only. Report real progress only.
- **Settings › Playback › Smart transitions** (mockup screen 7):
  - A toggle, on for mixes; "Use for everything" is off by default.
  - The job list, each with its state and "since" time.
  - Stop, Retry failed, and "Prepare whole mix now" (progress and Stop).
  - The Transition analysis storage figures.
- Expose `transitionPrepState(for:)`.
- Tests: windowing on track change, skip-if-cached, cancel, the Wi-Fi wait, and failure → retry,
  with the analyzer and resolver injected as protocols.

**M5 `feat(audio): execute planned transitions`**
`Sources/Audio/AudioPlayer+Transition.swift`, alongside the crossfade code, which stays as the
fallback.
- **Plan** current → next when the queue is a mix, or everywhere when the global toggle is on.
  Recompute when prep state changes, and publish the plan.
- **Prepare** about 20 s ahead:
  - Build the item with `buildItem`.
  - `seek(to: entryTime, toleranceBefore: .zero, toleranceAfter: .zero)`, then
    `preroll(atRate: blendRate)`.
  - Set `audioTimePitchAlgorithm = .timeDomain` and
    `automaticallyWaitsToMinimizeStalling = false`.
  - A remote item that isn't likely to keep up by `exitTime − 5 s` downgrades to `.plainCrossfade`
    with `notBuffered`.
- **Sync start:** map the outgoing track's `exitTime` to host time through its timebase, then call
  `incoming.setRate(_:time:atHostTime:)`.
- **Gain:** `AVMutableAudioMixInputParameters.setVolumeRamp` for equal-power curves on both items,
  plus `gainMatchDB`.
- **Tempo return:** step `rate` to 1.0 once per beat over `rateRampBeats`.
- **Drift check:** at 2 beats in, if |drift| > 15 ms, trim `rate` by ±0.5% for one beat. Log
  alignment in DEBUG builds.
- Skip, pause, seek or a queue edit cancels cleanly, the way `cancelCrossfade` does. Refactor
  `finishCrossfade`'s hand-over into a shared helper.
- **Device gate — stop and report if it fails.** Test 5 local constant-tempo pairs on a real
  device. If the median absolute alignment error is over 20 ms, don't ship. Report the numbers and
  propose moving scheduling to `ParsoAudioPlayback`/`ParsoDJEngine`. The owner does the listening
  test.
- Tests: static helpers for the host-time math, the rate ramp schedule and downgrade decisions.

**M6 `feat(mix): build and preview a mix`** (mockup screens 1–3; must meet the §1 design bar)
- **Schema v31:** a `playlist_mix` table (`playlistId` PK, FK cascade; `shape`, `seed`,
  `lockedJSON`, `transitionOverridesJSON`, `updatedAt`, `syncID`). CloudKit sync is **deferred**
  (the playlist order already syncs), recorded here on purpose. Add a migration test.
- **Entry points:**
  - A Listen **"Build a Mix"** card.
  - A playlist menu **"Mix This Playlist"**.
  - Mood and Find results **"Make a Mix"**.
  - Track context menu **"Start a Mix From This Track"**.
- **Build sheet** (`Form`, medium/large detents):
  - Source.
  - Shape (four rows, each with a sparkline and a one-line description).
  - Length (about 30, 60 or 90 min, or all).
  - Generate.
- **Preview:**
  - **Arc chart** (Swift Charts): BPM per position with Camelot point labels, plus energy.
  - Summary line and a **"Why This Mix?"** button.
  - Rows with BPM and key as text, and a **transition chip** between rows. Tapping a chip opens
    Why This Transition.
  - Swipe actions: Lock, Swap (runners-up), Remove.
  - Toolbar: Regenerate (keeps locks), Play, Save as Playlist. From a playlist it also offers
    **Apply Order**, with an Undo toast.
  - A **"Not placed (N)"** section with reasons and actions: Analyze now (live state), Add at end,
    Remove.

**M7 `feat(mix): why this mix, why this transition`** (mockup screens 4–5; must meet the §1 design bar)
All copy is rendered from the M1 reasons in plain language, and each term is explained the first
time it appears.
- **Why This Mix?**
  - The shape sentence.
  - The sources.
  - How the start was chosen.
  - The arc chart.
  - Stats.
  - **Trade-offs**: the weakest edges, worst first, each with its `unavoidable` reason.
  - Left out, and why.
  - A per-position "Why here?" with its reasons and the runners-up ("*Y* would have clashed:
    8A → 3B").
- **Why This Transition?**
  - Two aligned mini waveforms over the overlap, with phrase markers (`Canvas`, with an
    accessibility summary).
  - The **"What you'll hear"** sentence.
  - The reasons list: key relation explained, tempo change, which phrase and why, silence skipped,
    loudness matched.
  - Confidence.
  - The downgrade explanation with live prep state and **Prepare now**.
  - **Audition**, which seeks to `exitTime − 10 s` through the M5 engine.
  - **Use a Plain Fade Here**, which writes a per-edge override.

**M8 `feat(mix): transitions visible while playing`** (mockup screen 6)
- Now Playing and Up Next: a next-transition chip with a countdown ("Blend in 0:42 · Why?") and
  live prep state.
- The mini accessory shows a style label during a blend.
- README: a "Mixes" section, including what it doesn't do (no bass-swap EQ, no stems).

### Phase R — Release (FINAL: start only after C1–C3, A1–A11 and M1–M8 are all committed)

**R0 is the entry gate. Do not begin R1 until every box is checked.**
- [ ] All commits C1–C3, A1–A11 and M1–M8 are on `main`, and the M5 device gate passed.
- [ ] `scripts/design-ratchet.txt` is at zero, apart from allowlisted entries.
- [ ] The UI smoke suite and `make test-ui-regression` were run by hand and pass.
- [ ] A VoiceOver-only walkthrough (Build a Mix → Why → Audition → Play) was completed on a device.
- [ ] Native-speaker review is done for all six languages (R1), and no catalog entry is still
      `needs_review`.

Steps:
- **R1 Translation review (owner and testers).**
  - Recruit one native speaker per language through TestFlight, and give them
    `docs/l10n/REVIEW.md` and the per-language "What to Test".
  - The agent applies their fixes in `fix(l10n): <lang> review` commits and flips each entry to
    `translated`. Update the glossary whenever a reviewer changes a term.
- **R2 App Store Connect setup (owner).**
  - iPhone and Apple Watch only.
  - Remove or retire any macOS app record or Mac TestFlight builds.
  - Make sure iPad isn't listed as supported.
  - Localized metadata (name, subtitle, description, keywords, What's New) in all seven languages:
    the agent drafts it into `docs/release/metadata/<lang>.md`, and reviewers check it with the
    in-app strings.
- **R3 Store assets.**
  - Screenshots in both appearances, including one at a large text size and one in `zh-Hans`.
  - A 30-second preview video: Build → Why This Transition? → Audition.
  - The agent may script simulator captures; the owner approves the final assets.
- **R4 Ship.**
  - Submit for review, and release.
  - Submit a featuring nomination in App Store Connect for the Mixes launch.
  - Publish a press page with the privacy story in one paragraph.
- **Icon:** the designer icon is wired in (A11) for iPhone and Watch. Before release, check it on device.

---

## 4. Out of scope (so nobody adds it "helpfully")

- Bass-swap/EQ-kill transitions, stems, MIDI, recording, cue editing.
- Any deck or performance UI.
- CloudKit sync of `playlist_mix`.
- iPad support of any kind, and any macOS app (native, Catalyst, or "Designed for iPhone").
- Shipping to the App Store while any string is still `needs_review` (TestFlight is fine).
- New remote-library providers.
