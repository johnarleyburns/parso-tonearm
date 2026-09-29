# Platterhead DJ — Focus Deck redesign: agentic implementation handoff

You are picking up work in the `parso-tonearm` repo. **This file is the operating brief
for the DJ surface redesign.** Read it fully before touching anything, then read
[`MOCKUP_TEXT.md`](MOCKUP_TEXT.md): every string, control home and gesture is specified
there, and it is canonical. Do not re-litigate the design.

`CLAUDE.md` at the repo root loads automatically and wins over this file on process
(Swift 6 hard rule, work on `main`, no branches, one task per commit, ask before
`git push`, never `--no-verify`, no silent background work). Where this file and repo
reality disagree about *code*, repo reality wins; stop and report the mismatch.

---

## 0. Starting a session

**One session per task, one commit per task.** Each task below names the files it
touches and the spec sections it needs. A fresh session reads this file, `CLAUDE.md`,
the named `MOCKUP_TEXT.md` sections, and the named source files — nothing else.

Before the first task, commit the plan files and the mockup on `main`:

```bash
git add docs/plans/dj-focus-deck/ docs/plans/mockups/dj-focus-deck-mockups.html
git commit -m "docs: DJ Focus Deck redesign spec, mockups and handoff"
```

Views are built against `docs/plans/mockups/dj-focus-deck-mockups.html` for look and
against `MOCKUP_TEXT.md` for copy and behaviour; the text wins where they differ.

### Kickoff prompt (paste into a fresh session, replacing `Tn`)

> Read `docs/plans/dj-focus-deck/HANDOFF.md` in full, then `CLAUDE.md`, then the
> `MOCKUP_TEXT.md` sections that task **Tn** lists.
>
> Implement **task Tn only**. Confirm every file and symbol the task names against the
> code before editing; if something doesn't match, stop and report instead of improvising.
> Meet every acceptance check listed for Tn. Commit on `main` with the message the task
> gives; do not branch. Ask before pushing.

---

## 1. What exists today (verified 2026-09-28 at `4ec8acf`)

| Thing | Where | Notes |
|---|---|---|
| DJ entry view | `Sources/Features/DJ/DJView.swift` → `struct DJView` (≈ line 1630) | Also used by `Sources/AppMac/MacRootView.swift`. Presents `DJLoadSheet` and `DJHelpSheet` (both `private` in this file). |
| Model | same file: `DJPerformanceModel` (`ObservableObject`, ≈ 111–1515), `DJDeckState` (≈ 46–110), `DJAudioBacker` (`private`, ≈ 1122) | 3,133-line file — over the 400-line rule (`docs/plans/refactor-400-lines/STATUS.md`). |
| Current surface | `Sources/Features/DJ/DJV2Surface.swift` (869 lines) | Grid-of-buttons layout on `DJGridLayout`; all subviews `private`. |
| Pure DJ logic | `Sources/Domain/DJGridLayout.swift` (485 lines) | `DJPadMode`, `DJControlID`, `DJHelpContent`, `DJKnobMapping`, `DJFaderMapping`, `DJLoopState`, `DJJogMapper`, `DJCueTransport`, … |
| Design system | `Sources/DesignSystem/GlassSurface.swift`, `Palette.swift` | `glassSurface()` already honours Reduce Transparency and keeps chrome non-hit-testable. |
| Tests | `Tests/DJGridLayoutTests.swift` et al. | `swift test` compiles **only** `TonearmCore` — `Sources/Features`, `Sources/DesignSystem` and `Sources/App` are excluded in `Package.swift`. |

**Consequences that shape every task:**

1. **Anything you want unit-tested goes in `Sources/Domain/`** as pure, `Sendable` types. Views stay thin and call them.
2. View code is verified by an Xcode build, not `swift test`. After every view task, run both builds from `CLAUDE.md` (iOS scheme with `-destination 'generic/platform=iOS Simulator'`; **never** `-sdk`), plus a macOS build of the Mac app scheme because `DJView` is shared.
3. New files need `make project` (not bare `xcodegen generate`); commit the regenerated `project.pbxproj`, never hand-edit it.
4. Every new Swift file stays **under 400 lines**.
5. The model stays an `ObservableObject`. Migrating it to `@Observable` is out of scope.

---

## 2. Target architecture

```
Sources/Domain/
  DJSurfaceMap.swift          T2  control → tier/home coverage contract
  DJPerformPages.swift        T3  pad pages, auto-loop and beat-jump sizes, labels
  DJWaveformTouchPolicy.swift T4  waveform gesture → model action
  DJCoachPolicy.swift         T5  beginner coach tip selection
  DJChipReadout.swift         T3  deck-chip readout strings
Sources/Features/DJ/
  Model/                      T1  DJPerformanceModel*.swift, DJDeckState.swift, DJAudioBacker.swift (moved)
  Shared/                     T1  DJWaveformCanvas.swift, DJKnob.swift, DJFader.swift, DJMeter.swift (extracted from V2)
  Focus/
    DJFocusSurface.swift        T6  root: layout switch, portrait/landscape, sheets
    DJFocusGlass.swift          T6  glass modifier (native Liquid Glass + fallback)
    DJFocusTitleBar.swift       T6
    DJDeckChips.swift           T6
    DJWaveformCard.swift        T7
    DJTempoRow.swift            T8
    DJTransportRow.swift        T8
    DJPadTabs.swift             T9
    DJPadGrid.swift             T9
    DJFocusDock.swift           T10
    DJMixerSheet.swift          T11  (+ DJMixerChannelCard.swift, DJMixerMasterPage.swift)
    DJDeckOptionsSheet.swift    T12
    DJBothDecksLayout.swift     T14
    DJCoachCard.swift           T14
    DJFocusLandscape.swift      T15
```

`DJView` keeps ownership of the model, the Load sheet and the Help sheet. It switches
between `DJV2Surface` (classic) and `DJFocusSurface` on
`@AppStorage("dj.surface")` (`"focus"` | `"classic"`) until T17 deletes the classic surface.

### Liquid Glass

Minimum deployment is iOS 27, so the native SwiftUI glass APIs are available on iPhone.
Put **all** glass decisions in one modifier, `DJFocusGlass`, so nothing else branches
on availability:

- iOS 26+ / macOS 26+: `.glassEffect(.regular.interactive(), in: shape)`. Group
  adjacent glass (tab row, dock, chips) in a `GlassEffectContainer`.
- Earlier macOS, or Reduce Transparency: fall back to the existing `glassSurface(cornerRadius:)`.
- Tints: deck colour at 16% for the focused chip; never tint pads with glass.

Confirm the exact API spelling against the installed SDK before using it. If it differs,
adapt inside `DJFocusGlass` only.

---

## 3. Tasks

Each task is one commit. "Checks" must all pass before committing. The pre-commit hook
runs `swift test`; the Xcode builds are your responsibility.

### T1 — Split the DJ model out of `DJView.swift` (pure move)

- **Spec:** none (behaviour must not change).
- **Do:** move `DJDeckID`, `DJOutputMode`, `DJLoadPhase`, `DJDeckState`, `DJPerformanceModel` and `DJAudioBacker` into `Sources/Features/DJ/Model/`. Split the model into `DJPerformanceModel.swift` plus `+Transport`, `+Loops`, `+Pads`, `+Mixer`, `+Tempo`, `+Loading`, `+Recording` extensions, each < 400 lines. `private` members that extensions now need become `fileprivate` → **internal** only where a cross-file extension requires it; comment each widened member `// internal for DJPerformanceModel+X`. Also extract the V2 waveform canvas, knob, faders and meter into `Features/DJ/Shared/` as internal views (V2 keeps using them).
- **Checks:** zero logic diffs (reviewer can diff moved blocks); iOS, watchOS and macOS builds green; `swift test` green; DJ smoke-tested by hand on the simulator (load, play, cue, sync).
- **Commit:** `refactor(dj): split DJView.swift model and shared views into files`

### T2 — `DJSurfaceMap`: the coverage contract

- **Spec:** MOCKUP_TEXT §7.
- **Do:** in `Sources/Domain/DJSurfaceMap.swift` add `enum DJSurfaceTier { case always, mixer, deckOptions }`, `enum DJSurfaceHome` (cases per §7: `deckChips`, `waveform`, `transport`, `padTabs`, `pads`, `tempoRow`, `dock`, `titleBar`, `mixerChannels`, `mixerMaster`, `deckOptions`, `toolPage`) and `static func home(for: DJControlID) -> (DJSurfaceTier, DJSurfaceHome)` implemented as an **exhaustive `switch` with no `default`**, so adding a `DJControlID` fails to compile until it has a home.
- **Tests:** `Tests/DJSurfaceMapTests.swift` asserts each §7 row; asserts that every `DJHelpContent` topic's controls resolve (guards help ↔ layout drift).
- **Commit:** `feat(dj): control-to-surface coverage map`

### T3 — Pad pages and chip readouts (pure)

- **Spec:** §1.2, §1.6, §1.7.
- **Do:**
  - Add `DJPadMode.beatLoop` and `.beatJump` (not persisted, so safe). Keep `.loop` as the In/Out page.
  - `DJPerformPages`: the tab list (`Hot Cue`, `Loop`, `Pad FX`, `Beat Jump`); `alternate(of:)` (`beatLoop ↔ loop`, `fx ↔ beatFX`); `autoLoopBeats = [0.25, 0.5, 1, 2, 4, 8, 16, 32]`; `beatJumpBeats = [-1, 1, -4, 4, -16, 16, -32, 32]`; `func padLabel(mode:index:state:) -> (title: String, caption: String)` returning the exact §1.7 copy (move the label table out of `DJV2Pad` so both surfaces share it).
  - `DJChipReadout.text(...)` returning §1.2 strings from plain inputs (bpm, remaining, isPlaying, synced, loadPhase, onAir).
- **Tests:** every label in §1.7 for every mode; readout table in §1.2 including the unanalysed `—` case.
- **Commit:** `feat(dj): focus-deck pad pages and chip readouts`

### T4 — Waveform touch policy (pure)

- **Spec:** §1.3, §4.3.
- **Do:** `DJWaveformTouchPolicy.action(phase:isPlaying:touchMode:heldFor:translation:width:) -> DJWaveformTouchAction` with cases `.seek`, `.nudge`, `.scratch`, `.frameSearch`, `.flick`, `.focus`, `.none`, matching the §1.3 table (hold threshold 0.35 s). `enum DJWaveformTouchMode { case nudge, scratch }` maps to `DJDeckState.vinyl`.
- **Tests:** one test per table cell; non-finite inputs → `.none`.
- **Commit:** `feat(dj): waveform touch policy`

### T5 — Coach policy (pure)

- **Spec:** §5 coach table.
- **Do:** `DJCoachPolicy.tip(for: DJCoachSnapshot) -> DJCoachTip?`. The snapshot is a plain struct (loaded/playing/synced flags per deck, crossfader, `keysCompatible: Bool?`, a dismissed-tip ID). Priority is top-to-bottom as in the table. **Module boundary:** `TonearmDiscovery` depends on `TonearmCore`, not the reverse, so the policy must not import Discovery. The view layer (T14) computes `keysCompatible` with `MusicalMatchPolicy.compatibleKeys(for:)` and passes it in; `nil` (a key unknown) never produces the clash tip.
- **Tests:** each row, the priority order, and that dismissal suppresses a tip only until the situation changes.
- **Commit:** `feat(dj): beginner coach policy`

### T6 — Focus surface scaffold: glass, title bar, deck chips

- **Spec:** §0, §1.1, §1.2.
- **Do:** create `DJFocusSurface` (portrait stack only) with `DJFocusGlass`, `DJFocusTitleBar` and `DJDeckChips` (tap, context menu, readouts via `DJChipReadout`). Add the `dj.surface` switch in `DJView` defaulting to **`classic`** for now, plus a hidden toggle in Settings › DJ › `Layout` (`Focus` / `Classic`).
- **Checks:** builds green; with `focus` selected the new header renders and the rest of the screen is a placeholder `Color.clear`; accessibility labels as §1.1–1.2; nothing references `Tonearm` in user copy (`make ci-guards`).
- **Commit:** `feat(dj): focus surface scaffold, title bar and deck chips`

### T7 — Waveform card

- **Spec:** §1.3.
- **Do:** `DJWaveformCard` reuses the shared waveform canvas from T1 for both decks with one centre playhead, header phrase/bar readout, and the hint (persisted dismissal). Wire gestures through `DJWaveformTouchPolicy` to the existing model methods (`movePaused`, `nudge`, `scratch(_:by:width:)`, `flick`, `beginScratch`/`endScratch`, `selectDeck`, zoom).
- **Checks:** on a device or simulator, drag stopped = seek, drag playing = nudge, hold-drag = scratch; the 30 fps tick budget is unchanged (no extra `@Published` writes per frame).
- **Commit:** `feat(dj): focus waveform card with touch-policy gestures`

### T8 — Tempo row and transport

- **Spec:** §1.4, §1.5.
- **Do:** `DJTempoRow` (±0.1% with hold-repeat, drag-as-fader via `setTempoPercent`, double-tap reset, long-press fine slider, key chip, `•••`); `DJTransportRow` (CUE via the existing cue gesture, Play, SYNC with long-press master). Sync-locked tempo shows `SYNC` and the §1.4 toast.
- **Checks:** CDJ CUE semantics identical to V2 (hold-preview, cue-then-play latch); 44 pt targets.
- **Commit:** `feat(dj): focus tempo row and transport`

### T9 — Pad tabs and pad grid

- **Spec:** §1.6, §1.7.
- **Do:** `DJPadTabs` (segmented, tap-again alternate, two-dot indicator, tool-page banner with `Done`); `DJPadGrid` rendering `DJPerformPages` labels. Add model methods, in the T1 `+Loops` extension: `autoLoop(_ id:, beats:)` (quantized start, `setLoop(active: true)`, same pad again exits) and `beatJump(_ id:, beats:)` (quantize-aware seek). Hold-to-delete ring on hot cues. Haptics per §0.
- **Checks:** every page's pads trigger the same model calls the V2 pads did (In/Out, Pad FX, Beat FX, Key shift, Grid); new auto-loop and beat-jump behave per §1.7.
- **Commit:** `feat(dj): focus pad tabs, pad pages, auto loop and beat jump`

### T10 — Dock

- **Spec:** §1.8.
- **Do:** `DJFocusDock`: library button → `onLoad(activeDeck)`; crossfader using `DJFaderMapping.snapped` with a centre haptic; mixer button with an off-centre dot (`any EQ/filter/trim ≠ 0.5`). Pin it above the home indicator (keep V2's 34 pt minimum-bottom rule).
- **Commit:** `feat(dj): focus dock with crossfader`

### T11 — Mixer sheet

- **Spec:** §3.
- **Do:** `DJMixerSheet` with detents and background interaction as specified; `Channels` page (two `DJMixerChannelCard`s using the shared knob, fader and meter) and `Master` page (isolator + `flatMix`, bass swap, output mode, recording). Knobs: double-tap reset and a VoiceOver adjustable action.
- **Checks:** every control in §7 tier 2 is reachable and drives the same model call as V2; the sheet does not stop audio or reset focus.
- **Commit:** `feat(dj): focus mixer sheet`

### T12 — Deck options sheet

- **Spec:** §4.
- **Do:** `DJDeckOptionsSheet`, bound to the focused deck, including the entries that open tool pages and Help (the sheet dismisses first, then the pad grid switches).
- **Commit:** `feat(dj): deck options sheet`

### T13 — Load sheet additions

- **Spec:** §2.
- **Do:** the target `A | B` segmented control, compatibility badges (reuse `MusicalMatchPolicy`), and `Hold to replace` on on-air targets. `DJLoadSheet` stays in `DJView.swift` unless it must move; if it does, move it whole into `Features/DJ/DJLoadSheet.swift` in this commit.
- **Commit:** `feat(dj): load sheet deck target and compatibility badges`

### T14 — Both-decks layout and coach card

- **Spec:** §5.
- **Do:** `DJBothDecksLayout`, `DJCoachCard` (driven by `DJCoachPolicy`), the `Focus | Both decks` switch, and Settings › DJ › `Show layout switch` and `Coach tips`. Coach state is visible and dismissible (CLAUDE.md "no silent magic").
- **Commit:** `feat(dj): both-decks layout with beginner coach`

### T15 — Landscape

- **Spec:** §6.
- **Do:** `DJFocusLandscape`, reusing the V2 jog behaviour through the shared views from T1.
- **Checks:** iPhone landscape on the smallest and largest simulator; nothing clipped; 44 pt targets.
- **Commit:** `feat(dj): focus landscape controller layout`

### T16 — Help copy, identifiers, smoke lane, flip the default

- **Spec:** §7, §8.
- **Do:** rewrite `DJHelpContent` bodies for the new layout (no "top row is deck A, LOAD A…"); add `.accessibilityIdentifier("dj.focus.<element>")` to every interactive element; add a manual UI smoke test `UITests/DJFocusSmokeUITests.swift` (load → play → set hot cue → open mixer → close) — **run by hand, never wired into CI or hooks**; implement the §8 empty and error states; change the `dj.surface` default to `focus`.
- **Checks:** `DJSurfaceMapTests` still green; manual pass of `docs/plans/dj-device-test-script.md` on device, extended with the Focus flows.
- **Commit:** `feat(dj): make Focus Deck the default DJ surface`

### T17 — Delete the classic surface (owner sign-off required)

- **Gate:** the owner explicitly approves after at least one TestFlight cycle with Focus as the default.
- **Do:** delete `DJV2Surface.swift`, `DJV2PortraitLayout` and its tests, the `dj.surface` setting and the Settings toggle; keep the shared views.
- **Commit:** `chore(dj): remove classic DJ surface`

---

## 4. Definition of done (whole programme)

- Every `DJControlID` has a home (compile-time via the exhaustive switch in `DJSurfaceMap`).
- The portrait Perform screen shows **no more than 25 interactive elements** at once (V2 has ≈ 60). Count it in T16 and write the number in the commit body.
- Every new file is under 400 lines; `make ci-guards` is green; Swift 6 is warning-free.
- VoiceOver can operate load → play → sync → crossfade → hot cue with no sighted help.
- Reduce Transparency and Reduce Motion are both honoured (§0).
- The Mac app still builds and its DJ view still works (it uses the same `DJView`).

## 5. Things not to do

- Don't change audio or engine behaviour; this is a surface redesign. The only new model methods are `autoLoop` and `beatJump(beats:)` (T9).
- Don't add a `default:` to any `switch` over `DJControlID` or `DJPadMode`.
- Don't add new user-facing settings beyond `Layout`, `Show layout switch` and `Coach tips`.
- Don't wire UI tests into CI, hooks or `make test-swift`.
- Don't push without asking.
