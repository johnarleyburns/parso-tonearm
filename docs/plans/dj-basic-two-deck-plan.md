# Basic two-deck DJ tab — implementation plan

Status: **ready for implementation review**. Not yet implemented — this is a planning
document only, no Swift source is touched by it.

Mockups: [`docs/plans/mockups/dj-basic-two-deck-mockups.html`](mockups/dj-basic-two-deck-mockups.html)
— the DJ surface with Deck A controls active, the same surface with Deck B controls active, and
the Load-a-track sheet (My Music reused, LOAD instead of PLAY). The focused layout decisions are
also summarized in [`dj-basic-two-deck-mockups.md`](dj-basic-two-deck-mockups.md). Indexed by
anchor; every anchor referenced from this doc is verified to exist in the HTML (§9).

## 0 · One-paragraph summary

Add a fourth tab, `.dj`, that shows a **single fixed portrait screen**: three equal vertical
thirds — two stacked 3-band waveforms with minimaps in the top-right of each waveform header,
bottom-centered elapsed/remaining time and bottom-left BPM readouts, deck controls (switchable A/B) in
the middle, and always-visible two-deck mixer controls on the bottom. The audio engine is not
built from scratch: `ParsoDJEngine` (product of the `parso-audio-engine` package, **already
pinned at exact 1.2.2** in this repo's `Package.swift`, just not yet imported) is a complete,
tested, two-deck DJ engine — decks, mixer, EQ, crossfader, cues, loops, pads, jog/scratch, sync —
and this plan's job is almost entirely SwiftUI + view-model wiring on top of it, plus a small
number of named gaps. No paywall: DJ is free, matching the rest of the app (§1.3).

## 1 · Reconciliation — what already exists, what this plan does with it

### 1.1 There is currently no DJ code and no DJ tab in this app

Checked fresh this session, not assumed:

- `Sources/App/AppState.swift:12-14` — `enum AppTab: Int, CaseIterable { case listen, myMusic,
  settings }`. Three tabs, no `.dj` case, comment says "Four root tabs (down from six)" and a v3
  history note: *"DJ/Transition Lab removed (four tabs → three)."*
- `find . -iname "*DJ*"` under `Sources/` returns nothing. There is no `Sources/DJ/`, no
  `TonearmDJ` target, in this repo, at all.
- `git log`: `b5b279f feat!: remove DJ tab, Transition Lab, and the TonearmDJ target` (preceded by
  `96cbbbb`, `db3d142`, `d082417`, `27f0abf` — the same build-out-then-rip-out arc `docs/plans/
  dj-phase-1..5-*.md` and `dj-transition-lab-removal-plan.md` document). The owner's own words in
  that removal plan: *"study removing Transition Lab and the DJ tab entirely as I don't find them
  useful."* Everything under `Sources/DJ/` (analysis, engine, semantic, stems, recording — ~550KB)
  was deleted along with it.
- `Sources/Support/SupportDevelopmentStore.swift:1-13` confirms the business decision (2026-09):
  *"Tonearm has no gated Pro features... there is no longer a Pro entitlement/paywall."* `grep`
  for `ProEntitlement`/`FoundersGrant`/`guru.parso.tonearm.pro` across `Sources/` returns only
  unrelated matches (`ParsoAudioEngine`, `DiscoveryModelResources`, etc. — no DJ paywall code).

**Conclusion: this plan is not resurrecting, replacing, or reconciling with any live DJ code or
UI.** It is greenfield inside the app. The five `dj-phase-*.md` planning docs describe a much
larger, already-deleted iPad/iPhone "Pro performance workspace" (stems, recording, MIDI hardware,
paywall, twin-deck landscape, bank drawers) — **none of that is this plan's scope**, and none of
it is being revived. Where this plan's design overlaps with a decision those docs already made
well (e.g. "the jog is pure, touches the engine only via transport intents" — phase 4 commit
4.8), it is noted as *independently arrived at*, not inherited, because there is no code left to
inherit from.

### 1.2 The engine those old plans built by hand now exists, pre-built, in PAE — reuse it wholesale

This is the load-bearing finding of this research pass. `parso-audio-engine`'s `README.md:3-6`:

> *"A permissively-licensed (MIT) audio engine that reproduces the full software functionality of
> a Pioneer DDJ-FLX4 — two decks, a two-channel mixer, hot cues, loops, all eight performance-pad
> modes, Beat FX / Color FX, Smart Fader / Smart CFX, a sampler, mic, monitoring, sync, recording,
> and offline track analysis (BPM, key, waveform, structure, loudness)."*

`ATTRIBUTION.md:75-93` in that repo confirms the mechanism: PAE's `ParsoAudioAnalysis` and
`ParsoDJEngine` products are **ports of this exact app's deleted `Sources/DJ/` code**
("Phase 5: `AudioDecode.swift`... verbatim", "Phase 5: verbatim (Ellis-style DP beat tracker)",
etc.) — carried into the shared package as the old DJ tab was being torn out of the app, so the
DSP and engine work from `dj-phase-1..4` was **not thrown away**, it was **promoted into PAE**
where it is reusable, already unit-tested there (`swift test` green per PAE's own `current_status.md`/
README "Status" section), and versioned independently of this app's tab decisions.

`parso-audio-engine/Package.swift` already declares the product:
```
.library(name: "ParsoDJEngine", targets: ["ParsoDJEngine"])
```
and this app's own `Package.swift:21` already pins
`.package(url: ".../parso-audio-engine.git", exact: "1.2.2")` — a version that post-dates
`ParsoDJEngine`'s introduction (PAE's own tags run ...1.2.0 → 1.2.1 → 1.2.2; `ATTRIBUTION.md`'s DJ
rows are already present at 1.2.2). **No PAE version bump is needed.** What's missing is purely
this app's own `Package.swift`/`project.yml` — `ParsoDJEngine` is not yet listed as a dependency
of any target here (`grep -n "ParsoDJEngine" Package.swift` → no hits). Commit 1 below adds it.

The engine surface (`Sources/ParsoDJEngine/ParsoDJEngine.swift`, ~2,800 lines, all `@MainActor`,
Swift 6 strict concurrency clean) gives this plan, concretely:

| Class | What it owns |
|---|---|
| `DJEngine` (`init(sampleRate:maxFramesPerRender:)`) | top-level facade: `mixer`, `decks`, `start()`, `telemetry()` |
| `Deck` | `load(_:buffer:)`, `play()`, `pause()`, `setCue()`/`jumpToCue()`/`cuePlayPress()`/`cuePlayRelease()`, `loopIn()`/`loopOut()`/`reloopExit()`, `setHotCue(_:)`/`jumpHotCue(_:)`, `padPress(_:)`/`padRelease(_:)`, `jogTouchBegan()`/`jogMoved(_:)`/`jogTouchEnded()`, `sync()`/`setAsMaster()`/`unsync()`, `waveform: Waveform?`, `beatGrid: [TimeInterval]`, `effectiveBPM`, `isPlaying` |
| `Mixer` | `channelA`/`channelB: Channel`, `crossfader: Double (-1...1)`, `crossfaderCurve`, `master: MasterOut`, `beatFX`, `smartCFX` |
| `Channel` | `trim`, `eqLow`/`eqMid`/`eqHigh` (dB, −∞…+6), `fader` (0...1), `faderCurve`, `cuePFL` (headphone pre-listen), `crossfaderAssign: XFAssign`, `peakMeter`/`peakHold` |
| `Monitoring` | `cueMasterMix`, `headphoneLevel`, `cueMode`/`splitCue` |
| `SmartCFX` | single 0…1 `amount` + `preset` (Wash/Filter/Gate) — the DJM "Color FX" knob |
| `WaveformPyramid`/`WaveformBin` (in `ParsoAudioAnalysis`) | multi-resolution min/max/RMS **with `bandRMS: [Float]` (low/mid/high)** — the recordbox-style 3-band waveform, already computed at analysis time, already attached to `Deck.waveform` on load |

**This plan's engine work is almost entirely wiring**, not DSP. See §3 for the exact class this
app adds (`DJWorkspaceModel`) and §4 for the per-control mapping table.

### 1.3 No paywall, no entitlement gate — confirmed current

Per §1.1's `SupportDevelopmentStore.swift` doc comment, DJ is free. This plan adds **no**
`ProCapability`/`EntitlementStore` gate anywhere in the DJ surface — unlike the deleted phase-4
plan's `PaywallView`/`FoundersGrant` machinery, which does not apply here and is not being
revived.

### 1.4 This is deliberately smaller than the deleted DJ engine's UI, on purpose

Explicitly **not** reused from the old phase docs (§7 states these as non-goals with reasons):
twin-deck landscape mode, bank drawers/edge sliders, iPad workspace module slots, stems, live mic
input, recording/export, MIDI hardware, Smart Fader auto-transitions, Transition Lab/
`TransitionPlanner` suggestions, key-lock/pitch-bend beyond stock sync. The user's brief is
explicit: *"all it should do is load the DJ surface and nothing else"* — get two decks, mixing,
and controls working and sounding good, first.

## 2 · What to research in PAE — findings, control by control

Covered exhaustively in §4's mapping table. Headline findings:

- **3-band EQ**: `Channel.eqLow`/`eqMid`/`eqHigh`, driven by the C DSP core's Linkwitz–Riley
  isolator EQ. Already exists; nothing to build.
- **3-band waveform coloring**: `WaveformPyramid`/`WaveformBin.bandRMS` (`ParsoAudioAnalysis/
  WaveformPyramid.swift:75-108`), computed with the **same 200 Hz / 2 kHz LR4 crossover as the
  mixer's own EQ** (`WaveformPyramid.swift:126-129` — "the §26A.2 band splitter... the same
  crossovers as the mixer's three-band EQ" ), so the waveform's low/mid/high coloring and the
  EQ's band split are provably the same three bands, not two independently-tuned approximations.
- **BPM / beat-grid**: `Deck.beatGrid: [TimeInterval]`, populated on `load()` from
  `TrackAnalysis.tempo.beatPositions` (`ParsoDJEngine.swift:1001-1002`). `effectiveBPM` reads
  live.
- **Crossfader / gain mixing**: `Mixer.crossfader (-1...1)`, `crossfaderCurve` (`.smooth`/
  `.linear`/`.sharp`), `Channel.crossfaderAssign: XFAssign (.a/.b/.thru)`.
- **Cue points / loops**: `Deck.setCue()`/`cuePlayPress()`/`cuePlayRelease()` (CDJ-style
  press-jump/release-return cue), `loopIn()`/`loopOut()`/`reloopExit()`, `setHotCue(_:)` ×8 slots
  with `hotCueBank` support (this plan uses bank 0 only — 8 pads, not 16).
- **Real-time pitch/tempo/sync**: `Deck.sync()`/`setAsMaster()`/`unsync()`, `tempoPercent`,
  `TempoRange`.
- **Jog wheel / scratch**: `Deck.jogTouchBegan(pressure:)`/`jogMoved(deltaSamples:)`/
  `jogTouchEnded()`, plus `MobilePlatterGestureSample`/`MobilePlatterGestureMapper`
  (`ScratchPatterns.swift:26-181`) — a **pure, already-built** touch→jog-motion mapper for a
  circular platter gesture (contact-relative rotation), exactly the shape the deleted phase-4 plan
  wanted to hand-build as `JogGestureModel` (`dj-phase-4-engine.md` commit 4.8). Reuse it instead
  of rebuilding it.
- **Headphone cue**: `Channel.cuePFL`, `Monitoring.cueMasterMix`/`headphoneLevel`/`splitCue`.
- **"Bass fader" / "CFX" mixer knobs**: mapped explicitly in §4 — see the note there; PAE's
  literal names differ slightly from the user's DJM-style vocabulary and the mapping choice is
  justified, not assumed.
- **Stereo/Split L/Split R**: **named gap** — PAE's `CueMode` (`off`/`splitOutput`/`cueInPlace`/
  `multichannel`) covers headphone-cue split, not a master-bus stereo/mono-split-to-L/split-to-R
  switch. Flagged honestly in §4's row for it, with the smallest-scope resolution.

## 3 · Architecture

### 3.1 View hierarchy (SwiftUI, matching this app's established pattern)

Reference pattern confirmed from `Sources/Features/MyMusic/MyMusicView.swift` and
`Sources/Features/Library/LibraryView.swift`: a `View` struct holding `@EnvironmentObject var
appState: AppState` (+ `player: AudioPlayer` where playback-adjacent), `@State`/`@StateObject`
view-model, `Palette.*` tokens, no third-party UI framework.

```
DJTabView                              (Sources/Features/DJ/DJTabView.swift)
├── @EnvironmentObject appState: AppState
├── @EnvironmentObject player: AudioPlayer          (only for handing off "now playing" state
│                                                     when leaving the tab — decks own transport)
├── @StateObject model: DJWorkspaceModel            (Sources/Features/DJ/DJWorkspaceModel.swift)
├── .navigationBarHidden / .statusBarHidden-style chrome suppression — "load the DJ surface and
│   nothing else": no now-playing mini-player overlay, no GlassDock TransferPill duplication
└── body: DJSurfaceView (fixed-ratio VStack, portrait-only — §3.3)
    ├── DJWaveformStripView            (top third)
    │   ├── DJDeckWaveformView(deck: .a)   — waveform + header minimap + bottom BPM/time/track-name overlay
    │   └── DJDeckWaveformView(deck: .b)
    ├── DJDeckControlsView             (middle third)
    │   ├── DeckPicker (A / B segmented control)
    │   └── DJDeckControlPanel(deck: model.selectedDeck)
│       ├── TransportControls (play/pause, cue)
│       ├── LoopControls (in / out / loop toggle, beside transport)
    │       ├── LoadTrackButton → DJLoadTrackSheet (My Music reuse, §3.4)
    │       ├── HotCuePadGrid (8 pads)
    │       └── JogWheelView
    └── DJMixerControlsView            (bottom third, both decks always visible — not switched)
        ├── ChannelStrip(deck: .a)  — vol fader, bass fader, CFX, headphone cue toggle
        ├── CrossfaderControl
        ├── ChannelStrip(deck: .b)
        └── StereoSplitControl
```

`Sources/DesignSystem/Palette.swift` tokens (`Palette.bg`, `.ink`, `.ink2`, `.brass`, `.hairline`,
etc.) are used throughout — no new design-token file.

### 3.2 Audio engine wiring

`DJWorkspaceModel` is the one `@MainActor @ObservableObject` session model (mirrors the deleted
phase-4 plan's "one `WorkspaceModel` for every performance surface" principle §2.9, arrived at
independently here because it is simply the right shape for two decks driven by one engine, not
because that code survived):

```swift
@MainActor
final class DJWorkspaceModel: ObservableObject {
    let engine: DJEngine                 // ParsoDJEngine.DJEngine(sampleRate: 48_000, maxFramesPerRender: 512)
    @Published var selectedDeck: DJDeckSlot = .a   // drives which deck's controls show in the middle third
    @Published var deckAState: DJDeckDisplayState  // waveform scroll pos, BPM, elapsed/remaining, track title
    @Published var deckBState: DJDeckDisplayState
    @Published var loadSheetTarget: DJDeckSlot?    // non-nil while the Load sheet is presented

    func load(_ track: TrackRow, into deck: DJDeckSlot) async throws { ... }  // decode via existing
        // AudioDecode path (ParsoAudioCore.PCMBuffer / this app's existing file-reading substrate,
        // §4's Load row), analyze via ParsoAudioAnalysis if not already cached, engine.decks[deck].load(...)
    func play(_ deck: DJDeckSlot) { engine.decks[deck.index].play() }
    // ... one thin method per control in §4, each a direct call into `engine`/`Deck`/`Channel`/`Mixer`
}
```

`DJEngine.start()` opens one `AVAudioEngine` graph with two deck source nodes feeding the shared
`Mixer` (EQ/crossfader/limiter chain) → master output — this graph is internal to `ParsoDJEngine`
and this app never touches `AVAudioEngine` directly, matching how `ParsoAudioPlayback` is already
consumed elsewhere in this codebase without the app owning engine internals. `DJWorkspaceModel`
owns the `DJEngine` instance for the tab's lifetime; entering the tab calls `engine.start()` (or
resumes an already-started engine if the user left and came back — decks keep playing), leaving
the tab does **not** stop playback (matches "always visible, always in the user's control" —
CLAUDE.md's no-silent-background-work rule: a DJ mix the user is running must not silently stop
just because they tapped away, and must be visibly resumable/stoppable from wherever it's
running — see §7 for the one small addition this requires outside the DJ tab itself).

### 3.3 The exact 1/3-1/3-1/3 layout — fixed-ratio `VStack`, justified

Portrait-only, so **no `GeometryReader`** is needed for the split: a `GeometryReader` earns its
keep when a layout must respond to more than one aspect ratio or orientation class, and this
surface explicitly never will (`UIRequiresFullScreen`-style, or `.avoid(.autorotate)`-equivalent
handling — actual orientation lock covered in §4's Load row / §6 non-goals — the plan pins
`WindowGroup`'s supported orientation to portrait for this tab in `Info.plist`/scene config). A
fixed-ratio `VStack` with three `.frame(maxHeight: .infinity)` children inside a `GeometryReader`
that only supplies the **total height once** is the simplest correct implementation:

```swift
GeometryReader { geo in
    VStack(spacing: 0) {
        DJWaveformStripView(model: model)
            .frame(height: geo.size.height / 3)
        DJDeckControlsView(model: model)
            .frame(height: geo.size.height / 3)
        DJMixerControlsView(model: model)
            .frame(height: geo.size.height / 3)
    }
}
.ignoresSafeArea(edges: .bottom)
```

(A `GeometryReader` is still the cleanest way to read the one number — total available height —
that three `.frame(maxHeight:)` children can't derive from `Spacer()`s alone without also fighting
the safe-area/home-indicator inset on a phone; this is a one-shot read, not a per-child layout
negotiation, so it doesn't reintroduce the "GeometryReader for everything" anti-pattern the rest
of the app avoids elsewhere.) Each third is internally a normal `VStack`/`HStack` — no further
GeometryReader nesting.

## 4 · Control-by-control mapping

Every control the user listed, mapped to (a) the PAE API, (b) the new Swift type/file that owns
it in this app, (c) what its unit test looks like. "New Swift file" paths are all under
`Sources/Features/DJ/` unless noted; "Tests" are under `Tests/DJTabTests/` (flat, matching this
repo's existing `Tests/*.swift` + a few subdirectories convention — no `TonearmDJ` SPM target is
recreated, this is plain app-target test code against the view models, per §1.1's "greenfield"
finding).

| Control | PAE API | New Swift type/file | Unit test |
|---|---|---|---|
| Play/Pause | `Deck.play()` / `.pause()` / `.isPlaying` | `DJWorkspaceModel.togglePlay(_ deck:)` | `DJWorkspaceModelTests.testTogglePlayFlipsEngineDeckState` — fake `DJEngine`-shaped protocol seam (`DJTransportControlling`), asserts play called once per tap, pause on second |
| Cue | `Deck.setCue()` / `.jumpToCue()` / `.cuePlayPress()` / `.cuePlayRelease()` | `DJDeckControlPanel`'s cue button → `DJWorkspaceModel.cuePress(_:)`/`cueRelease(_:)` (press = CDJ-style preview-jump, release = return) | `CuePressReleaseTests` — press while paused jumps+plays, release returns to cue point, press while playing sets a new cue (matches CDJ convention) |
| Headphone cue | `Channel.cuePFL`, `Monitoring.cueMasterMix`/`headphoneLevel`/`splitCue` | `DJChannelStripView`'s cue toggle → `DJWorkspaceModel.setHeadphoneCue(_ deck:enabled:)` | `HeadphoneCueTests` — toggling A does not affect B's `cuePFL`; `cueMasterMix` clamps to 0...1 |
| Loop in / Loop out / Loop | `Deck.loopIn()`/`loopOut()`/`reloopExit()` | `LoopControls` view, placed beside transport in the primary row → `DJWorkspaceModel.loopIn(_:)`/`loopOut(_:)`/`toggleLoop(_:)` | `LoopMathTests` — loop-out before loop-in is a no-op (not a crash / not a negative-length loop); re-pressing "loop" while active exits (reloop toggle semantics) |
| Load a track (My Music, LOAD not PLAY) | App-side decode (existing `AudioDecoder`/file-reading substrate — **not** re-deriving `ParsoAudioAnalysis`'s decode from scratch; reuse whatever `AudioPlayer`/`LibraryStore` already use to get `PCMBuffer`s) → `Deck.load(_ analysis:buffer:)` | `DJLoadTrackSheet.swift` — **wraps `MyMusicView`'s existing list**, passing a `loadAction: (TrackRow) -> Void` closure instead of `MyMusicView`'s own `player.play(tracks:startAt:source:)` call (mirrors `LibraryView.swift:328`'s `cta` button exactly, swapped for one LOAD button, no Shuffle) | `DJLoadTrackSheetTests` — tapping a row calls the injected load closure with that exact `TrackRow`, never calls `player.play`; sheet dismisses after load starts, shows a load-in-progress state while analysis/decode runs (no silent multi-second hang — CLAUDE.md's no-magic-background-work rule) |
| 8 hot-cue pads | `Deck.setHotCue(_:)`/`jumpHotCue(_:)`/`deleteHotCue(_:)`, `padPress(_:)`/`padRelease(_:)` | `HotCuePadGrid.swift` — pad has "set" (empty slot, tap sets a hot cue here) vs "jump" (filled slot, tap jumps) vs "long-press to clear" states, driven by `DJWorkspaceModel.padTapped(_ deck: _ index:)` | `HotCuePadStateTests` — pure state-machine test: empty→set on tap, filled→jump on tap, filled→cleared on long-press, all 8 slots independent per deck |
| Jog wheel / scratch | `MobilePlatterGestureMapper` (`ScratchPatterns.swift:54-181`, already pure) → `Deck.jogTouchBegan(pressure:)`/`jogMoved(_ sample:)`/`jogTouchEnded()` | `JogWheelView.swift` — a `DragGesture` translated to `MobilePlatterGestureSample`s fed to the mapper, no new gesture math written here (reuses PAE's mapper wholesale, unlike the deleted phase-4 plan which built its own `JogGestureModel` because no reusable one existed at the time) | *No new pure-math test needed here* — `MobilePlatterGestureMapper` is already tested in PAE. This app's test (`JogWheelViewModelTests`) only asserts the `DragGesture` → `MobilePlatterGestureSample` translation (angle/radius from a touch point) is correct, and that jog input for deck A never calls into deck B's engine reference |
| Per-deck volume faders | `Channel.fader` (0...1), `Channel.faderCurve` | `DJChannelStripView`'s vertical `Slider` → `DJWorkspaceModel.setFader(_ deck: value:)` | `FaderTests` — value clamps 0...1; `.linear` curve is default and byte-identical to raw position (matches PAE's own `FaderCurve.gain` contract, tested here only for the plumbing, not re-testing PAE's curve math) |
| Crossfader | `Mixer.crossfader` (-1...1), `Mixer.crossfaderCurve` | `CrossfaderControl.swift` — horizontal slider centered at 0 | `CrossfaderPlumbingTests` — dragging to full-left sets `crossfader == -1`, full-right `== 1`, center `== 0`; curve selection (`.smooth` default) passed through unmodified |
| Bass fader | **Mapping decision**: `Channel.eqLow` (dB, −∞...+6) used as a **kill-style bass control** — a single knob/slider mapped 0...1 → −∞ dB (fully counter-clockwise, "bass kill", the literal 2-channel-mixer "bass fader" behavior) ... +6 dB (fully clockwise), not the full 3-band EQ. This is a deliberate simplification: the user's spec lists "bass fader" as a discrete mixer control alongside CFX/split, matching a simple 2-channel club-mixer bass knob, not the DJM-style 3-knob EQ column — the 3-band `eqLow`/`eqMid`/`eqHigh` full EQ strip is **not** exposed as three separate knobs in this basic pass (non-goal, §6) | `BassFaderControl.swift` → `DJWorkspaceModel.setBass(_ deck: position:)` mapping `position(0...1)` to `eqLow` via a documented curve (linear dB below center, hard kill at 0) | `BassFaderMappingTests` — position 0 → eqLow == -.infinity (kill); position 1.0 → eqLow == 6; position 0.5 → eqLow == 0 (unity, matches the engine's own untouched default so a centered bass knob is silent-safe) |
| CFX | **Mapping decision**: `SmartCFX` (`amount: Double 0...1`, `preset: Int` Wash/Filter/Gate) — this is PAE's own name for exactly this control (README: "Smart Fader / Smart CFX"; class doc: "a curated ... chain", the single-knob DJM Color-FX-style effect), applied to **both decks via the master bus** (`fx.assign = .master`, already how `SmartCFX.apply()` wires it) rather than per-channel `colorFX`/`colorAmount` (which exist on `Channel` too but are a different, per-channel control not asked for here) | `CFXControl.swift` — one knob + a 3-way preset picker → `DJWorkspaceModel.setCFX(amount:)`/`setCFXPreset(_:)`, backed by `mixer.smartCFX.isEnabled`/`.amount`/`.preset` | `CFXPlumbingTests` — `amount == 0` leaves `smartCFX` inert (`isEnabled` still settable but `apply()`'s own guard on PAE's side is what's authoritative — this test only proves the app sets `isEnabled = true` exactly when `amount > 0`, matching the class's own documented contract) |
| Stereo / Split L / Split R | **Named gap, honestly flagged**: PAE has no master-bus stereo/mono-split-to-L/split-to-R switch — `CueMode`'s `.splitOutput` is a **headphone monitoring** split (master→one ear, cue→other), a different feature entirely (`Monitoring.swift`, §2). A true "STEREO / SPLIT L / SPLIT R" master-output switch (seen on club mixers to route mono-summed content differently to house-left/house-right feeds) is a per-channel-pair **output routing** concern that no class in `ParsoDJEngine` currently exposes. Resolution for this basic pass: **build the smallest honest version in the app**, not in PAE — a 3-way `enum MasterOutputMode { case stereo, splitLeft, splitRight }` applied as a post-`MasterOut` pan/sum stage using `RealtimeInsert` (`ParsoDJEngine.swift:384-389`, the documented realtime-effect-insert seam meant for exactly this kind of app-supplied DSP tap) — a `MasterOutputRouter: RealtimeInsert` that sums to mono and hard-pans L or R. This is the **one piece of new DSP this plan writes**, deliberately small (≤ 10 lines of sample math), installed via `mixer.setInsert(_:at: .master)` | `MasterOutputRouter.swift` (`Sources/Features/DJ/Engine/`) | `MasterOutputRouterTests` — `.stereo` passes L/R unchanged; `.splitLeft` sums L+R into the left channel and silences right; `.splitRight` the mirror; all three preserve peak level (no unexpected clipping/gain change) — a pure buffer-in/buffer-out test, no engine needed |
| Minimap (per waveform) | `Deck.waveform: Waveform?` — same pyramid, rendered at a coarser level/zoomed-out scale in a small overlay | `DJDeckWaveformView`'s header-aligned top-right minimap, reads a low-resolution pyramid level + the deck's current playhead fraction | `WaveformMinimapLayoutTests` — minimap playhead marker position is `currentSample / totalSamples` clamped 0...1; pure geometry math, no rendering assertions (SwiftUI rendering isn't unit-testable here, matching this repo's existing pattern of testing the *math* behind a view, not the view) |
| 3-band waveform + BPM + beatgrid + elapsed/remaining + track name (display-only, top third) | `Deck.waveform.bins[].bandRMS`, `Deck.beatGrid`, `Deck.effectiveBPM`, `Deck` playhead, `TrackAnalysis`/loaded `TrackRow` title | `DJDeckWaveformView.swift` — BPM bottom-left; elapsed/remaining bottom-center; minimap top-right in the header | `WaveformBandColorMappingTests` — bandRMS[0..2] (low/mid/high) map to three fixed `Palette` colors consistently; `RemainingTimeTests` — remaining = duration − elapsed, never negative, formats `-M:SS` |

## 5 · Test plan

### 5.1 Real unit tests (run in `swift test`, this app's normal CI gate — CLAUDE.md: "A commit
runs `swift test` only")

Every row's rightmost column above is a real `XCTestCase` under `Tests/DJTabTests/`, following the
established split this codebase already uses (`KeepPlayingPicker`/`IntentResolver`): **pure logic
lives in a type with no `AVFoundation`/`ParsoDJEngine` import where possible**
(`BassFaderMapping`, `MasterOutputRouter`'s sample math, `HotCuePadGrid`'s state machine,
`WaveformMinimapLayout`, `RemainingTime` formatting), and the thin shell that actually calls into
`Deck`/`Channel`/`Mixer` is tested against a **protocol seam**, not the real engine, so these tests
run fast and don't need real audio hardware:

```swift
protocol DJTransportControlling: AnyObject {
    func play(); func pause(); var isPlaying: Bool { get }
    func setCue(); func jumpToCue(); func cuePlayPress(); func cuePlayRelease()
    // ... one method per row above that DJWorkspaceModel calls
}
extension ParsoDJEngine.Deck: DJTransportControlling {}   // real conformance, zero new code
final class FakeDeck: DJTransportControlling { /* records calls, in-memory state */ }
```

`DJWorkspaceModel` is generic/injectable over this protocol (or holds `any DJTransportControlling`
per deck) so `DJWorkspaceModelTests` never touches `AVAudioEngine`. This mirrors the deleted
phase-4 plan's own conclusion for its "engine offline tests" (§2 item 5: "the offline engine
harness... asserts sample-accurate output" for *engine* correctness) but that layer is **already
PAE's job and already covered by PAE's own test suite** — this app's tests only need to prove its
own view-model plumbing calls the right `Deck`/`Channel`/`Mixer` method with the right value, not
re-prove the DSP.

### 5.2 OPTIONAL — device/simulator regression suite

Per CLAUDE.md's explicit rule ("CI runs `swift test` only... `TonearmUIRegressionTests`/
`TonearmUIRegression`... lives in its own target and scheme... keep that separation"): if this
plan grows a heavier end-to-end pass later, it goes in the **existing** `TonearmUIRegressionTests`
target (`project.yml:285`/`485`, already wired with its own scheme, already excluded from
`make test-swift`) as new **lanes**, not a new target and never wired into the pre-commit hook.
Suggested lanes (optional, not required for this plan to be considered done):

- `djload` — load a real fixture track into deck A from the My Music sheet, assert playback starts
  and the waveform view renders non-empty bins.
- `djmix` — load two fixture tracks, play both, move the crossfader across its range, assert the
  recorded master-bus RMS reflects both sources at the expected positions (reusing the deleted
  phase-4/M5 regression suite's own proven "acoustic proof, not just wiring" philosophy —
  `dj-regression-suite.md`'s three-layer table — as prior art for *how* to write this lane, not as
  code to resurrect).
- `djpads` — tap all 8 hot-cue pads on deck A in sequence, assert 8 distinct jump events fire.

This section stays **optional and explicitly deferred**; nothing in §8's phased build order
depends on it landing.

## 6 · Non-goals for this first pass

Matching "all it should do is load the DJ surface and nothing else" literally:

- **No track browsing polish** in the Load sheet beyond reusing `MyMusicView`'s existing list with
  the button swapped (no DJ-specific search/filter/sort).
- **No recording** — `MixRecorder` exists in PAE and is deliberately not wired up. A future pass
  can add a record button; this one doesn't.
- **No stems** — `StemKind`/`armStems`/etc. exist in PAE, unused here. Full mix only.
- **No effects beyond what's listed** — `BeatFXUnit`'s full 20-effect catalog, `ColorFX` per
  channel, `MicInput`, `Sampler` pads (distinct from hot-cue pads) are all present in PAE and all
  intentionally not exposed. Only `SmartCFX` (mapped to "CFX") is used.
- **No autoplaylist / DJ-assist / TransitionPlanner suggestions** — `TransitionPlanner`,
  `AudioTransitionProposal`, `SmartFader`'s auto-transition arm/tick machinery exist in PAE and are
  intentionally unused. The user mixes manually; nothing suggests transitions.
- **No landscape / twin-deck / iPad workspace** — portrait phone only, one fixed layout, no
  `WorkspaceModel`-style orientation switching (the deleted phase-4 `TwinDeckView`/orientation
  design is explicitly not being rebuilt).
- **No MIDI/hardware controller support** — touch-only.
- **No tempo-sync/master or key-lock / pitch-bend UI** — `Deck.sync()`/`setAsMaster()`/
  `tempoPercent`/`keySync`/`keyReset` exist in PAE, but this basic surface keeps them out of the
  switchable deck-control panel; there is no manual pitch fader or key-shift control.
- **No paywall** — confirmed free app-wide (§1.3); nothing here changes that.

## 7 · The one thing this plan touches outside `Sources/Features/DJ/`

`Sources/App/AppState.swift:12-14`'s `AppTab` gains a fourth case, `.dj`, and
`Sources/App/RootView.swift`'s tab switch gains `case .dj: DJTabView()`, and
`Sources/Features/Chrome/GlassDock.swift`'s `TabBar` items array gains a DJ entry (mirroring
exactly how the now-deleted Transition Lab tab was wired per `dj-transition-lab-removal-plan.md`
§2, in reverse). Per that same file's §2 "Tab-bar consequence" note, this also needs a fresh
`lastActiveTab` persistence-key version bump (`"lastActiveTab.v3"` → `"v4"`,
`AppState.swift:42`'s established pattern — a saved `.settings == 2` under the current 3-tab
scheme must never silently resolve to whatever the new 4th slot becomes) so an old persisted tab
index is never misread across the shape change.

Per CLAUDE.md's no-silent-background-work rule (§3.2's "leaving the tab does not stop playback"
decision): if a DJ mix is running and the user switches to another tab, **some** always-visible
indicator that a DJ session is live and a one-tap way back to it is required — the existing
`GlassDock`/`MiniPlayer` pattern (`GlassDock.swift`'s `MiniPlayer` shown whenever
`player.currentTrack != nil`) is the established precedent for exactly this kind of "something is
running, stay informed, stay in control" surface, and the smallest correct move is a parallel
`DJSessionPill` (same slot/priority rules as `TransferPill`) rather than inventing new UI language.
This is called out explicitly because CLAUDE.md requires the status surface and stop/retry control
to land **in the same change** as the feature, not as a follow-up — so it is written into this
plan's commit sequence (§8, commit 6) rather than deferred.

## 8 · Phased build order

One commit per phase, on `main`, per this repo's session model (HANDOFF.md §0). Each phase leaves
`swift test` green and, from phase 3 onward, something tappable in the simulator.

1. **Dependency + skeleton** — add `ParsoDJEngine` to `Package.swift`/`project.yml`; add the `.dj`
   `AppTab` case + tab-bar wiring + persistence-key bump (§7); `DJTabView` shows a static
   three-thirds placeholder (colored rectangles, no engine yet) so the layout is visually settled
   first. Test: `AppTabPersistenceTests` (v3→v4 migration never misreads).
2. **`DJWorkspaceModel` + engine start/stop, one deck, no UI polish** — `DJEngine` instantiated,
   `Deck.load`/`play`/`pause` wired to two bare buttons, waveform strip shows deck A's real
   waveform once loaded. Proves the engine boots and a track plays audibly. Test:
   `DJWorkspaceModelTests` (fake-deck plumbing per §5.1).
3. **Load-track sheet** — `DJLoadTrackSheet` wrapping `MyMusicView`'s list with LOAD. Both decks
   loadable. Test: `DJLoadTrackSheetTests`.
4. **Deck controls (middle third)** — play/pause, cue, loop in/out/loop, A/B
   switcher. Test: each row's test from §4.
5. **Hot-cue pads + jog wheel** — `HotCuePadGrid`, `JogWheelView` over `MobilePlatterGestureMapper`.
   Tests per §4.
6. **Mixer controls (bottom third) + `DJSessionPill`** — faders, crossfader, bass fader, CFX,
   stereo/split (incl. the one new `MasterOutputRouter` DSP insert), plus §7's status-surface
   addition landing in the same commit as the mixer controls that make a DJ session "live."
   Tests: `CrossfaderPlumbingTests`, `BassFaderMappingTests`, `CFXPlumbingTests`,
   `MasterOutputRouterTests`.
7. **Minimap + beatgrid/BPM/elapsed-remaining/track-name overlay polish** — the remaining
   display-only pieces of the top third once both decks are fully controllable. Tests:
   `WaveformMinimapLayoutTests`, `RemainingTimeTests`,
   `WaveformBandColorMappingTests`.
8. **(Optional, not gating) regression lanes** per §5.2, whenever there's appetite for the
   heavier device pass.

Each phase is independently shippable behind the tab (nothing else in the app depends on the DJ
tab existing), so a working, audible, testable two-deck mix exists as early as phase 4 — loading,
playing, cueing and looping two tracks together — well before pads/jog/full mixer polish land.

## 9 · Mockup cross-reference verification

Every anchor this document links into `mockups/dj-basic-two-deck-mockups.html` is confirmed
present with `grep -c 'id="ANCHOR"' mockups/dj-basic-two-deck-mockups.html` returning `1`:

| Anchor | Section |
|---|---|
| `#w-surface-a` | Main DJ surface, Deck A controls selected |
| `#w-surface-b` | Main DJ surface, Deck B controls selected |
| `#w-load` | Load-a-track sheet (My Music reused, LOAD button) |

See the mockup file's own sticky table of contents for the same three anchors.
