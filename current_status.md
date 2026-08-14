# Current Status

Session working from `docs/plans/tonearm-mvp-ios/` — the operating brief is
`HANDOFF.md`, the implementation spec is `PLATTERHEAD_IOS_ARCHITECTURE.md`, and
the commit sequence is **Appendix M.1/M.2** of that spec. The M2 working plan is
`docs/plans/dj-phase-2-semantic.md` (commit sequence §5, audit table §9), the M3
working plan is `docs/plans/dj-phase-3-autoplaylists.md` (commit sequence §5,
audit table §9).

## Milestone

**M5 — the milestone where it becomes a DJ app** (spec §48.6 **re-scoped**, Appendix
M.6 rewritten), working from
`docs/plans/dj-phase-4-stems-recording.md`. Plan is on `main`; commits **5.1–5.12 landed,
5.13 to come**. Its on-device rows (real Demucs separation timing/thermal, AT-STEM-\* hardware,
the club-controller transfer test, and **the milestone's own end-to-end narrative**)
are user-owned and defer to a post-M5 device pass. M4 — the two-deck engine,
`AVAudioSession`, and StoreKit (the 3.0 Pro launch, spec §48.5, Appendix M.5) — is
**complete**: plan `5e8b731` + commits 4.1–4.13 are all on `main`. Its user-owned ship gates
(AT-THERM-1 on-device thermal/memory, AT-PLIST-2 on-device timing, AT-PLIST-7
listening) are deferred to a single post-M4 device pass. M3 (auto-playlists,
`docs/plans/dj-phase-3-autoplaylists.md`) is **complete** — commits 3.1–3.5 are all
on `main` (AT-PLIST-3 harness in 3.5 closed the last gate); its user-owned ship
gates (AT-PLIST-2 on-device timing, AT-PLIST-7 listening) are deferred to a post-M4
device pass. M2 (CLAP semantic embeddings + tiered vector store,
`docs/plans/dj-phase-2-semantic.md`) is complete; M1 (analysis stages 1–2 + thermal
governor) is fully committed.

## Commits on `main`

- **M5 5.12** — `4cbbf04` `feat(dj): finish + mixes + timeline + review listen + export, §37.4, §41.11-41.12, §18A.5, FR-REC-1/4/5/6/7 (M5 commit 5.12)`.
- **M5 5.11** — `c83fd84` `feat(dj): recording journal, crash/interruption recovery, finalize, §37.3-37.5, §34A.4, FR-REC-1/3, FR-ENG-8 (M5 commit 5.11)`.
- **M5 5.10** — `1f07de9` `feat(dj): record tap + encoder + segmented M4A, §37.2, FR-ENG-7 (M5 commit 5.10)`.
- **M5 5.9** — `6dc5f80` `feat(dj): gig crates — promotion, budgeted separation, LRU eviction, §41.17, §43.6, FR-PLIST-9, FR-ANL-9, FR-LIB-8 (M5 commit 5.9)`.
- **M5 5.8** — `118320d` `feat(dj): stem voices live on decks — StemSet summing reader, honest prepared state, live faders, §35.1, §36.5, FR-ENG-3 (M5 commit 5.8)`.
- **M5 5.7** — `0a90d68` `feat(dj): Demucs ODR + separation + content-addressed cache, §36, FR-ENG-3 (M5 commit 5.7)`.
- **M5 5.6** — `dee6a57` `feat(dj): genre libraries — Jamendo connector, curated genre picker, AT-GENRE-* (M5 commit 5.6)`.
- **M5 5.5** — `559b23a` `feat(dj): Beat FX echo — post-fader beat-synced delay, §35B transitions, AT-TRANS-1..5 (M5 commit 5.5)`.
- **M5 5.4a** — `495780f` `feat(dj): real-time render pump — .realtime mode, one render-closure body, session-first entry (M5 commit 5.4a)`.
- **M5 5.4** — `a6d59f3` `feat(dj): club ergonomics — per-channel strips, tempo faders, eight pads, CUE-left-of-PLAY, §53.11 identifiers (M5 commit 5.4)`.
- **M5 5.3** — `9bd2db6` `feat(dj): waveform render — band-split colour, composed grid, phrase ribbon, overview (M5 commit 5.3)`.
- **M5 5.2** — `f8f9db1` `feat(dj): analysis persistence — phrases, downbeats, real beat grid, band-split pyramid (M5 commit 5.2)`.
- **M5 5.1** — `69814f6` `feat(dj): app entry point + library → deck seam (M5 commit 5.1)`.
- **M5 plan (re-scope)** — `d108b09` `docs(dj): M5 re-scope — outcome milestone, reachability first, Jamendo/AAC (Appendix M.6)`.
- **M4 4.13** — `01d4acb` `feat(dj): paywall, purchase flow, memory ceiling (M4 commit 4.13)`.
- **Seed-fix** — `1290b31` `test(dj): seed the onset-noise test — fixes the SystemRandomNumberGenerator flake`.
- **M4 4.10** — `f9e77c9` `feat(dj): bank drawers, edge sliders, bottom-edge crossfader (M4 commit 4.10)`.
- **M4 4.9** — `113e8b7` `feat(dj): twin-deck landscape surface + orientation switch (M4 commit 4.9)`.
- **M4 4.8** — `fce2b16` `feat(dj): jog gesture model + jog view with phase ghost (M4 commit 4.8)`.
- **M4 4.7** — `91580c0` `feat(dj): iPhone portrait solo-deck surface (M4 commit 4.7)`.
- **M4 4.6** — `2bc6d4a` `feat(dj): dual-deck sync + telemetry + iPad workspace (M4 commit 4.6)`.
- **M4 4.5** — `c628e99` `feat(dj): time-stretch/key-lock/key-shift via AVAudioUnitTimePitch (M4 commit 4.5)`.
- **M4 4.4** — `6e3c0e9` `feat(dj): mixer — 3-band EQ, sweep filter, crossfader, master limiter (M4 commit 4.4)`.
- **M4 4.3** — `e595254` `feat(dj): single-deck play/cue/loop, sample-accurate (M4 commit 4.3)`.
- **M4 4.2** — `40903e7` `feat(dj): audio-session decision table and coordinator (M4 commit 4.2)`.
- **M4 4.1** — `211f431` `feat(dj): RT boundary — command ring, snapshot, RTGuard, offline engine harness (M4 commit 4.1)`.
- **M4 gate** — `a7615e5` `test(dj): AT-PLIST-8 gate 2.0s → 2.5s — owner runs Low Power Mode on AC`.
- **M4 gate** — `AT-PLIST-8 gate 2.5s → 4.0s` — prevent flaky failures while in Low Power Mode.
- **M4 plan** — `5e8b731` `docs(dj): M4 plan — real-time engine, audio session, purchase (3.0 Pro launch)`.
  Working plan for milestone M4 per handoff §8. Resolved decisions recorded up front:
  **`guru.parso.tonearm.pro` is repurposed as the single DJ product** — no `.pro.dj`,
  no Founders grant, T.4 collapses to one row (commits in 4.13); **deployment floor
  raised to iOS 18 / macOS 15 / watchOS 11** so the RT command ring uses the stdlib
  `Synchronization.Atomic` (no swift-atomics, no C shim); **`AVAudioSession` lives only
  in `Sources/DJ/Session/`** with a pure route/interruption decision table
  (`SessionPolicy`) so AT-SESS-\* is testable off-device; **offline engine harness =
  `AVAudioEngine` manual rendering** on the macOS host; the user-owned AT-THERM-1 and
  M3 ship gates (AT-PLIST-2/7) deferred to a single post-M4 device pass.
- **M3 (complete):** plan `c2415a5`; 3.1 `87155e5`; 3.2 `94ed3eb`; 3.3 `c7abb86`;
  3.4 `8e6d628`; 3.5 `98825bb` (AT-PLIST-3 shuffle-comparison harness closed the last
  gate). M2 (complete): plan `dbd01df`; model conversion `42cb3fd`; 2.1 `cba52bf`;
  2.2 `a0c1291`; 2.3 `3879013`; 2.4 `b9f5bb4`; 2.5 `45ecc8c`; plus `c6de224`
  (Play at any browse depth + Jellyfin demo onboarding). M1 commits
  `dd9cc35`…`fc81f2e`.

## Working on

**M5 — re-scoped, plan rewritten; 5.1–5.12 landed, commit 5.13 ahead.** The milestone is no longer
"stems, recording, gig crates" — it is **an outcome**, per the rewritten §48.6:

> Open the app → pick a genre (**electronic → techno**) → get a library of current,
> legally usable tracks ordered by interest → build a Deck A and a Deck B playlist →
> mix, using all five beginner transitions with the controls where a club-trained hand
> expects them → record a 20-minute set → **listen to it immediately, in the app** →
> share it as a file that plays.

**Why the re-scope.** After M4 the engine is complete and correct, and the product is
not usable: verified on `main` — **nothing outside `Sources/DJ/` references any
performance surface** (the only app-side `import TonearmDJ` is `AnalysisView`/
`AnalysisModel`; `RootView` has no DJ route), **`WorkspaceModel` holds no library
reference** so no real track can reach a deck, and **`AnalysisCoordinator.persist`
writes nothing to `phrase`, `downbeat` or `waveform_pyramid`** while `beat_grid` gets
`firstBeatSample: 0, beatCount: 0` — which is why every waveform in the product is
placeholder geometry. The stems/recording work would have landed on top of all three.

**M5 commit 5.2 — analysis persistence — complete (`f8f9db1`).** §19.4's render
contract is closed: the pipeline's computed artifacts now reach every destination
table instead of being dropped (FR-WAVE-1, AT-WAVE-1, §49.3 rule 9):

- `AnalyzeResult` widened from counts to the full contract — `BeatGrid`, downbeat
  indices, `[Phrase]`, `WaveformPyramid`, `energyCurve` + hopSeconds; `persist`
  writes them all in the **one existing transaction** (NFR-REL-1).
- New `Data/AnalysisArtifacts.swift` — the shared SQL writers (single source of
  row shapes) used by both the coordinator's single-transaction persist and the
  `DJLibraryStore` façade: `phrase`/`downbeat` are DELETE-then-INSERT, the
  single-row tables INSERT OR REPLACE, so **re-analysis is idempotent per version**
  and `grid_correction` never touches the immutable rows (§19.4 rules 2–3).
- **Real `beat_grid.firstBeatSample`/`beatCount`** (plus mean confidence) — the
  placeholder-zero defect is gone; the per-beat `beat_blob` (new `BEAT` layout,
  i64 samples + f32 confidences, §15.7 kind=0x03); `downbeat` rows anchor bar
  numbers; the band-split pyramid BLOB is FR-WAVE-2's only source.
- `Phrase` gains `startSample`/`endSample` so `phrase` rows are the §25 spans the
  ribbon draws; `track.detectedBPM` is now written from the real grid.
- `DJLibraryStore` gains `savePhrases` + the sibling artifact writers (the §10.1
  façade, never implemented through M4) and the read accessors `WaveformRepository`
  needs (`phrases`/`beatGrid`/`downbeats`/`waveformPyramid`/`energyCurve`).
- Tests: 3 `WaveformPersistenceTests` — **AT-WAVE-1** (a real click-track WAV is
  analysed and re-read: all five artifacts present with values equal to the
  deterministic pipeline output, `beat_grid` never carries placeholder zeros),
  re-analysis idempotence, and grid corrections still override without mutating
  the immutable rows. DJ-only — no `xcodegen generate` (plan decision 25). Full
  suite **1244 green** (1241 baseline + 3).

**M5 commit 5.4 — club-standard ergonomics — complete (`a6d59f3`).** The §41.9b
arrangement lands over mockup `ipad/07` (FR-TRANS-1/2, §42.7c, NFR-A11Y-6):

- `WorkspaceView` is relaid out to the club arrangement. The two decks' waveforms
  stack on **one shared playhead** at the top (§26A.5 view 2 — the overview +
  phrase ribbons per deck, the detail rows beneath), freeing the deck columns to
  be pure performance. Each deck column carries the club block: the **tempo fader
  on the outer edge** (rule 4, ±8% `ClubGeometry.tempoFaderRange`; `setTempo` →
  `setRate` with the ±8% clamp; VINYL/CDJ mode toggle rides the same outer column)
  beside the **jog centred** (the plain 248 pt platter — the bend-column jog
  module stays in the module slot's JOG option), the `HOT CUE · PAD FX · BEAT JUMP
  · SAMPLER` **mode selector** above **eight pads** in two rows of four (rule 5),
  and **CUE left of PLAY** at the deck's inner base (rule 3). The **mixer column
  is the two per-channel vertical strips** (rule 1 — TRIM compact → HI → MID →
  LOW → FILTER → vertical fader → CUE; `ClubGeometry.channelStripOrder`), the
  **crossfader horizontal and bottom-centre** (rule 2, `dj.mixer.crossfader`), the
  §35A **Beat FX block** below it (rule 7, honest-unavailable until 5.5's engine),
  and the master/limiter/thermal readouts. The per-deck queue moves into a browse
  sheet from the deck header (the compact crate-sheet pattern — FR-ENG-13 intact,
  and the column keeps its club geometry); the module slot stays (STEMS is 5.8's
  surface) with slimmed content; the jog sensitivity faders ride under the pads
  (the mixer is now the strips).
- **Compact (§42.7c):** the transferable core was already always-visible
  (crossfader, channel faders, edge filters, CUE-left-of-PLAY, jog); **ECHO** now
  has an always-visible button on both compact surfaces (`dj.fx.echo`,
  honest-unavailable until 5.5 — Echo Out's two controls both stay reachable
  without a drawer); EQ remains in the bank drawer.
- **Geometry tests updated, not deleted** (decision 19): `1fr 320px 1fr`, the
  ~416 pt deck column, `jogModuleWidth` ≤ both the derived (406 on 1180) and the
  normative (416) deck column. New model surface: `masterBarBeat` pure bar:beat
  math for `dj.master.bar` (§53.11) and per-deck tempo state.
- **§53.11 accessibility identifiers on every performance control**, across all
  three surfaces: `dj.deck.<a|b>.<play|cue|filter|fader>`, `dj.deck.<a|b>.eq.
  <low|mid|high>`, `dj.mixer.crossfader`, `dj.fx.echo`, and `dj.master.bar`
  exposing `bar:beat` (part of each control's contract, plan decision 27).
- Tests: 8 new `WorkspaceModelTests` (club mixer budget, strip reading order,
  CUE-left-of-PLAY, eight-pad geometry, tempo range + clamp + rate forwarding,
  echo beat set, master bar:beat math) + 4 updated geometry tests. Full suite
  **1262 green** (1244 baseline + 18); Swift 6 guard OK; app builds; iPhone +
  watch smoke tests pass in the pre-commit hook. No `xcodegen generate` (DJ-only,
  decision 25). **FR-TRANS-1/2, §41.9b, §42.7c, §53.11.**

**M5 commit 5.4a — the real-time render pump — complete (`495780f`).** The
**app now makes sound** (decision 26, §53.11) — the prerequisite found while
designing the regression suite, lettered `5.4a` so the recorded 5.5–5.13
sequence stays stable:

- `AudioGraph.Configuration` gains `rendering: .offline` (today's behaviour,
  unchanged, still the test default) and `.realtime`. `.realtime` skips manual
  rendering and connects the existing source nodes through
  `mainMixerNode → outputNode` (`format: nil`, so AVAudioEngine inserts the
  converter to the hardware rate); `start()` then pulls the graph on the audio
  thread. **One render-closure body, two drivers** — the closures are shared; the
  direct topology already advances the master clock inside `renderDecks`, and the
  time-pitch topology's deck-B node advances it once per callback in realtime
  (both decks read the same pre-advance `frameStart`; the offline driver keeps
  today's advance in `render`, so every existing acceptance test keeps its
  meaning). `render(_:)` refuses on a realtime graph with a dedicated
  `renderingUnavailableInRealtimeMode` error.
- **Session-first (§34A.2):** `DJWorkspaceAssembly.makeModel` (now async) enters
  the `AudioSessionCoordinator` in the normative order — category → preferences →
  activate → read back → build the graph — then builds a `.realtime` engine with a
  128-frame `maximumFrameCount` (matching the §34A.1 performing buffer, so the
  workspace's buffer-period/render-load readouts are honest). An unenterable
  session (refused Bluetooth route, activate failure) is an honest unavailable
  state, never a silently dead graph; on macOS (no `AVAudioSession`) the engine
  is still built — CoreAudio drives the realtime graph. `WorkspaceModel` retains
  the coordinator so its route/interruption marshalling survives (responses are
  consumed by the recording/service commits 5.10/5.11); `DJPerformanceSurface`
  gains an honest loading/unavailable split for the async assembly.
- Tests: `EngineOfflineTests.testRealtimeModeRefusesOfflineRender` (deterministic
  — a realtime graph refuses the offline pull) + the existing suite green
  unchanged; app target builds (the `DJHomeView` change is app-target code).
  The realtime pull was verified on the macOS host as the "app makes sound"
  proxy: a loaded deck advanced the master clock **1024 → 13312 in 0.25 s** with
  audio on the master bus. Full-suite run: **1262/1263 green** — the one failure
  the documented `SequencerTests` environmental gate (machine clock-capped by
  load; passed on re-run at 3.33 s once the machine settled). No `xcodegen
  generate` (edits existing files only, decision 25). **§53.11, decision 26.**

- **Commit sequence (plan §5).** Unblockers first: **5.1** app entry point + library →
  deck seam (§49.3a); **5.2** analysis persistence (§19.4); **5.3** the §26A waveform
  render; **5.4** club-standard control ergonomics (§41.9b, §42.7c); **5.4a** the
  real-time render pump (§53.11); **5.5** Beat FX
  echo + AT-TRANS-1..5 (§35A, §35B); **5.6** genre libraries (§18A, §41.1a). Then the
  original scope: **5.7** Demucs ODR + cache; **5.8** stem voices on decks; **5.9** gig
  crates + storage budget; **5.10** record tap + encoder;
  **5.11** journal + recovery;
  **5.12** Finish + Mixes + **the review listen**; **5.13** the transition coach.
  *(5.1–5.12 landed; 5.13 ahead.)*
- **New spec material** (all written, all cross-referenced): **§19.4** persisted
  analysis artifacts · **§26A** rekordbox-class waveform display · **§35A** the
  post-fader beat-synced echo · **§35B** the five transitions → control mapping ·
  **§18A** genre libraries · **§41.1a** genre picker · **§41.9b** club ergonomics ·
  **§42.7c** compact adaptation · **§41.18** transition coach · **§37.6** why M4A not
  MP3 · **§49.3a** the reachability invariant. New FR families **FR-WAVE-1..7**,
  **FR-TRANS-1..6**, FR-LIB-9/10, FR-REC-6/7. New AT families **AT-WAVE-\***,
  **AT-TRANS-1..5**, **AT-GENRE-\***.
- **Owner decisions taken this session (handoff §9 items):** the music source is
  **Jamendo, not the Free Music Archive** — FMA shut down their public API and their
  terms prohibit both hotlinked playback and scraped browsing, the two things the
  feature needs; the export format is **AAC/M4A, not MP3** — the platform ships no
  system MP3 encoder and `.mp3` would need a vendored LGPL encoder, deferred to M6.
  **One new network host** (Jamendo), owner-authorised; **still no new dependency**.
- **Only one piece of new DSP in the whole milestone:** the §35A echo. Four of the five
  transitions are already performable by the M4 engine — what they lacked was
  ergonomics and display, which is why the relayout and the waveforms are in the same
  milestone. The coder should not invent DSP for the other four.
- `xcodegen generate` **is** needed in 5.1 and 5.6 only (app-target + `Sources/Domain`/
  `Sources/Remote` files); 5.2–5.5 and 5.7–5.13 are DJ-only (plan decision 25).
- **Mockups:** `ipad/07-dj-workspace.html` rebuilt to the channel-strip layout with the
  §26A waveform stack; `ipad/09-recording-finish.html` gains the review listen;
  **new** `ipad/15-genre-picker.html` and `ipad/16-transitions.html`; `platterhead.css`
  gains the waveform/ribbon/channel-strip idioms; index + README + §40.5/40.6 inventory
  updated (iPad now 16/16).
- The on-device rows — real Demucs timing, the club-controller transfer test with three
  trained users, two coloured waveforms + two jogs inside the §43.3 budget, catalogue
  depth per sub-genre, and **the end-to-end narrative itself** — are the user-owned
  post-M5 pass, joining M4's deferred AT-THERM-1/AT-MEM-1.

**M5 commit 5.5 — the §35A post-fader beat-synced echo + AT-TRANS-1..5 — complete (`559b23a`).**
The one Beat FX M5 ships (decision 23) and the milestone's transition family
(§35A, §35B — FR-TRANS-3/4/5):

- `Engine/BeatEcho.swift` — the **pure §35A.2 control value** (`BeatEcho`: `enabled`/
  `beats`/`depth`/`feedback`, delay math `beats × 60/effectiveBPM × sampleRate` with a
  nominal-tempo fallback so the render thread never divides by zero, feedback
  **hard-clamped at 0.85** — a self-oscillating echo is a defect, not a feature) and the
  render-thread `BeatEchoLine` (fixed-capacity ring allocated at graph construction, a
  **read-pointer crossfade on beat-length change** — a pointer jump clicks — and
  `enabled = false` **continues reading the tail** until it decays below the noise floor,
  then bypasses at zero cost. This is what "echo out" means).
- **Graph placement is post-fader, pre-crossfader, per channel (§35A.1) — the whole
  design.** A pre-fader echo dies with the fader and Echo Out collapses into Fader Cut.
  `RTCommand` gains `setEchoEnabled/Beats/Depth/Feedback`; `PerformanceEngine` façade
  methods; `DeckState` pushes the control value into every channel's line and retunes the
  delay **once per callback from the master clock's effective tempo** (`applyEchoMasterBPM`
  — a tempo change moves the echo with it; a synced pair echoes in time with both decks).
- **Surfaces:** the mixer column's Beat FX block is **live** (per-channel A/B selector,
  the five §35A beat lengths, a drag depth track, the `dj.fx.echo` ON/OFF toggle); the iPad
  FX module slot's **ECHO pad is live** (RVB/FLTR/CRUSH stay honestly unavailable);
  the compact surfaces swap the honest-unavailable `EchoButton` for
  `EchoReleaseToCommitButton` — a single always-visible button whose **long-press
  release-to-commit flyout** carries channel/beats/depth (§42.7b idiom 3). Echo Out is a
  two-control transition, so ECHO and the fader are both reachable without a drawer. The
  flyout's frames and `releasedAction(at:)` are pure on `WorkspaceModel.EchoFlyout` — the
  engine is touched only on a release inside a commit target, nothing changes on the way
  out.
- Tests: 8 `BeatEchoTests` (delay length vs BPM, crossfade continuity — max sample delta
  stays inside the signal's own slope — monotonic decay, tail-then-bypass bit-exact,
  re-enable clears the bypass) + 7 `TransitionTests` — **AT-TRANS-1..5 in both halves**
  (decision 24): the **audio half** as scripted offline-render sequences with Goertzel
  band assertions (Bass Swap kills A's low while B's low and A's mid pass untouched,
  AT-TRANS-1; the filter sweep high-passes the outgoing deck and leaves the incoming
  spectrum unchanged, AT-TRANS-2; **the echo tail rings at the beat interval after the
  fader cut and decays monotonically to silence**, AT-TRANS-3, plus the disabled-path
  tail; the sharp-curve Fader Cut is a bounded no-zipper ramp, AT-TRANS-4; the hot
  two-deck Blend never exceeds the limiter ceiling and genuinely sums both decks,
  AT-TRANS-5) and the **layout half** asserting every transition's controls are present
  and reachable on both the §41.9b tablet and §42.7c compact surfaces (Echo Out's two
  controls never behind a drawer; Bass Swap's LOW lives in the spring-loaded bank drawer)
  + 4 `WorkspaceModelTests` (per-deck echo forwarding, §35A clamping, flyout release
  resolution incl. the slide-out cancel paths, flyout geometry fits the twin mixer
  column). Full suite **1289 green** (1262 baseline + 27); Swift 6 guard OK; app builds;
  smoke tests pass in the pre-commit hook. DJ-only — no `xcodegen generate` (decision 25).
  **FR-TRANS-3/4/5, §35A, §35B, AT-TRANS-1..5.**

**M5 commit 5.6 — genre libraries — complete (`dee6a57`).** The practice-material
connector that makes M5's exit narrative startable (§18A, §41.1a, FR-LIB-9/10) —
**free tier** (FR-LIB-7, `remoteLibraryJamendo` joins the registry):

- `SourceKind.jamendoGenre` (`Sources/Domain`); `JamendoGenreProvider` + `JamendoAPI` +
  the curated `JamendoGenreTree` behind the existing `RemoteLibraryProvider` seam,
  registered in `RemoteConnectorCatalog` (`jamendoGenre`, guided, no credentials).
  **Verified against the live API** (decision 20): Jamendo v3.0 exposes **no `/genres`
  method** — the read methods are albums/artists/autocomplete/feeds/playlists/radios/
  reviews/tracks/users and `GET /v3.0/genres` returns code 7 — so genre data is free-form
  `musicinfo.tags.genres` and the hierarchy is **curated here**, each node filtering the
  catalogue through `tags=` with `order=popularity_total` + `fullcount=true` +
  `include=musicinfo` + `audioformat=mp32` (all param shapes probe-verified).
- **A genre is an ordinary `Source(kind: .jamendoGenre, iaIdentifier: <path>)` row**
  (§18A.3): `electronic/techno` and `electronic` are different libraries; `browse(path:)`
  returns the popularity-ordered page; `resolve` hands back the stream URL; tracks flow
  through `RemoteTrackRowFactory` so FR-LIB-8 caching / analysis / decks need **no
  special-casing** (§18A.4). Sub-genre track IDs are exact fixture assertions.
- **Licence** travels at the source level (`licenseText: "Creative Commons — attribution
  kept"`) per the existing IA/built-in pattern — the schema has no per-track licence
  column; per-track artist/album/genre travel in each row (**deviation recorded**:
  §18A.5's per-track carry is satisfied structurally, to be revisited with 5.12's
  attribution). **`client_id` is an application credential** read from Info.plist
  (`JamendoClientID` / `TONEARM_JAMENDO_CLIENT_ID` build setting, added to `project.yml`);
  an unconfigured build is the honest `.notConfigured` state, never an empty library
  (§18A.6, the D-9 lesson).
- `GenrePickerModel` + `GenrePickerView` (mockup `ipad/15`): the curated top-level genres
  with expandable sub-genres, multi-select, lazily-fetched `fullcount` counts, the
  **equally-weighted Skip/Cancel**, the collapsed gating-nothing account checkbox, and the
  one-line licence/attribution note (§41.1a). Two doors: a **first-run onboarding page**
  (step 2, before local files) and the **Add source** flow (AddServerSheet presents the
  picker sheet for the jamendo connector). `AppState.addGenreLibrary` validates
  reachability before inserting. The picker model surfaces the honest catalogue error and
  refuses to silently no-op if the host never set its create seam.
- Tests: 16 `GenreLibraryTests` — **AT-GENRE-1..7** against **recorded fixtures**
  (decision 21, `Fixtures/jamendo/{techno,house,electronic,api-error}.json` served by a
  tag-keyed URLProtocol stub, no live network): genre→source identity, sub-genre
  distinctness, popularity-descending ordering (+ the request carries `order=popularity_total`),
  metadata/artwork/resolve, no-account request shape, unconfigured honest unavailable,
  licence/row passthrough, the standard-row-factory path to a deck, API-envelope and
  transport failure honesty, fullcount counts, free-tier registry + catalog, and the
  picker-model selection/add/probe/toggle tests. Suite 1289 → **1305 green**; Swift 6
  guard OK; app builds (xcodebuild verified); smoke tests pass in the pre-commit hook.
  **`xcodegen generate` committed** (project.yml + `Sources/Domain` + `Sources/Remote`,
  decision 25 — the regenerated pbxproj also carries the sitting 5.14 lane references,
  consistent with the documented scaffold state). **FR-LIB-9/10, §18A, §41.1a,
  AT-GENRE-\*, AT-FREE-\*.**

**M5 commit 5.7 — Demucs ODR + separation + cache + version stamp — complete (`0a90d68`).**
The §36 pipeline's delivery seam and its testable kernel (plan decisions 1, 5; §36, FR-ENG-3):

- `ModelTag.stems` joins the ODR tags and the existing `BundleResourceProvider` carries
  `DemucsStems.mlpackage`; `AnalysisVersions.stems = 1` (the cache-keyed version — a model
  upgrade invalidates cleanly, like `analysis_version`). New `Sources/DJ/Stems/` module:
  **`StemModel.swift`** — `StemKind` (vocals/drums/bass/other), `StemChunk` (a stereo Float32
  pair at a sample rate), the four-voice `StemSeparation`, the **`StemModelProviding` seam**
  (`version` / `isAvailable` / `separate(chunk:)` — **absence is a value, never an error**,
  FR-SEM-6, so the deck plays the full mix per §36.5), and the ODR `DemucsStemModel` shell
  that is honestly absent until the `.mlpackage` is registered and throws an explicit
  `conversionPending` for a present-but-unwired model (ADR-10 — the real conversion + ODR
  registration is the user-owned post-M5 step, like M2's `42cb3fd`).
- **`StemSeparator.swift`** — the pure chunk/overlap-add kernel (`StemChunking`: fixed 2¹⁷-frame
  chunks, 50% overlap, a **periodic Hann generated here because `vDSP_HANN_NORM` is
  energy-normalized and does not satisfy first-power COLA**; the window's `w[i] + w[i+hop] == 1`
  is what makes reconstruction exact), with vDSP doing the multiply/accumulate, and the
  pipeline `separate(pcm:)` (slice → model → window → overlap-add → four full-length voices;
  nil when the model is absent; empty-input, wrong-length voices and a mid-run disappearance
  are all **loud**, never a silent partial result).
- **`StemCache.swift`** — content-addressed, model-versioned: four 48 kHz stereo `.caf` files
  under `Caches/TonearmDJ/Stems/<contentHash>/<version>/` (backup-excluded, §13.1), the
  `stem_cache` row written in **one transaction** (INSERT OR REPLACE — re-store is idempotent);
  `load` resolves from the row's recorded relative paths and returns nil when a file is gone
  (**a row without files is absence, never corruption**); `evict` removes the on-disk directory
  only once no remaining row references it (content-hash sharing across tracks is honoured).
- **`DJMigrations+v4.swift`** — `stem_cache` plus §15.5's recording DDL **verbatim**
  (`performance_session`, `mix`, `mix_track_event`, `mix_asset`; decision 6), `dj_v4`
  registered in the migration order. The recording tables are unused until 5.10–5.12 but the
  migration is complete per the plan.
- Tests: 11 `StemSeparatorTests` (**the reconstruction golden across chunk boundaries** — a
  passthrough model reconstructs its input exactly in the interior; the pipeline is bit-for-bit
  the pure kernel; absence → nil; wrong-length and mid-run disappearance throw) + 9
  `StemCacheTests` (content-addressing incl. distinct-hash isolation, an exact 9600-frame voice
  round-trip through the CAF files — AVAudioFile drops a trailing partial block, so the writer
  chunks into ≤ 4096-frame calls, verified on host — idempotent re-store, **version
  invalidation**, row-without-files = absence, eviction incl. the shared-directory refcount) +
   2 new `DJSchemaTests` (v4 tables/indexes + the composite `stem_cache` PK). Suite 1305 →
   **1327 green** (8 skipped); Swift 6 guard OK; app builds (xcodebuild verified). DJ-only — no
   `xcodegen generate` (decision 25). **FR-ENG-3, §36.**

**M5 commit 5.8 — stem voices live on decks, honest disabled state — complete (`118320d`).**
The §35.1 reader's second slot and the model's honest stem status (plan decisions 3–4;
FR-ENG-3, §36.5 — **AT-STEM-\* engine rows**):

- `Engine/StemVoices.swift` — the pure **`StemSet`**: four `DeckSource`s of one track at the
  shared playhead with one shared grid, `@unchecked Sendable` exactly like `DeckSource`
  (§12.2). `DeckState` gains the **second armed slot** (`stemSetPointer`), per-voice smoothed
  gains + mute/solo state (fixed `StemKind.index` arrays), and a pre-allocated `stemScratch` so
  the render thread never allocates (§12.3). `RTCommand` gains `armStemSet` / `setStemGain` /
  `setStemMute` / `setStemSolo`; `PerformanceEngine` gains the façade methods + a
  `StemSetRegistry` (ownership-transfer boxes, the `SourceBoxRegistry` pattern).
- **The reader branches on the armed set** (§35.1): a deck with **no** stem set is byte-for-byte
  the current single-source reader (`readChunk` unchanged); an armed set sums the four voices
  through `readStemChunk` — per-voice one-pole gains advance once per sample (shared across
  channels, so L/R stay coherent), fold in mute/solo, then the EQ/filter/fader/echo/crossfader
  chain runs **once** over the summed voice. `referenceSource()`/`referenceGrid()` fall back to
  the armed set, so a stems-only deck still renders and the master clock, sync and echo read the
  set's grid (verified: 124 BPM from an armed set with no full-mix source).
- `WorkspaceModel` per-deck stem state — **`DeckStemStatus`** `unavailable / separating /
  prepared` with honest `label`s, and **`StemControlState`** (gains/mute/solo, `maxGain` 1.5).
  `resolveStems` on load queries the **`StemProviding` seam** (`StemLoader`: StemCache → decode
  each `.caf` to mono → `StemSetBox`); a cached version-matched set is **armed** and the status
  goes `prepared` (faders live), otherwise the deck is **disarmed** and plays the full mix with
  the honest `unavailable` status. **Fader setters are inert unless `.prepared`** — a disabled
  fader neither forwards nor moves (§36.5's "never a fader that looks live and does nothing").
  `markStemSeparation` renders `.separating` (driven by 5.9's §36.3 service).
- **Views:** the iPad STEMS module slot and the compact bank drawer's STEMS (the §2.1 two-fader
  budget) become **live when prepared** — a shared `StemFaderRow` (drag gain, tap-to-mute,
  `dj.deck.<a|b>.stem.<voice>` identifiers) — and render the honest disabled rows otherwise.
- Tests: 7 `StemVoiceTests` (**frame-exact four-voice summing at unity**, the **bit-identical
  fallback** — arming a passthrough set then disarming is sample-transparent and the no-stem
  path equals the reference; a stems-only deck reads its voices; gain/mute/solo settle correctly
  after the one-pole ramp; the armed set's grid drives the master clock) + 6 new
  `WorkspaceModelTests` (prepared load arms + live faders, unavailable load keeps full mix +
  **inert** faders, the separating state, status labels, unity defaults, gain clamp). Suite 1327
  → **1340 green** (8 skipped); Swift 6 guard OK; app builds (xcodebuild verified); smoke tests
  pass in the pre-commit hook. DJ-only — no `xcodegen generate` (decision 25).
  **FR-ENG-3, §35.1, §36.5, AT-STEM-\* (engine rows).**

**M5 commit 5.9 — gig crates: promotion, budgeted separation, LRU eviction — complete (`6dc5f80`).**
The §41.17 surface, the §43.6 disk budget, and the §36.3 lane (plan decisions 2, 11;
FR-PLIST-9, FR-ANL-9, FR-LIB-8 — **AT-STEM-\***):

- `Data/GigCrateRepository.swift` — `GigCrate`/`GigCrateTrack` records + the `GigCrateRow`/
  `GigCrateDetail`/`GigCrateTrackRow` read models. **Promotion from a playlist (FR-PLIST-9)** in
  one transaction: create the `gig_crate` row, copy the playlist's ordered items into
  `gig_crate_track`, stamping each track's **FR-LIB-8 `audioCached` flag** at promotion time
  (the `DeckLoader` file-exists probe — a partially-cached remote track is never deck-ready).
  `markPerformed` stamps `lastPerformedAt` (the LRU clock); `setStemsState`/`setAudioCached`/
  `refreshAudioCached`; `cratesByLRU` (oldest first; never-performed = oldest) +
  `evictableCrates` for the budget.
- `Perf/StorageBudgetService.swift` — the **pure** §43.6 policy (no I/O, fully testable):
  per-device-class stem budgets (iPhone 4 GB / iPad 12 GB) + waveform budgets (300/600 MB),
  the ~13 MB/track projection, **`mixesEvictable = false` always** (mixes are user content,
  never auto-evicted — the app asks, never chooses), and
  `plan(addingBytes:budget:currentStemsBytes:usages:protectedIDs:)` → a `StemPlan` whose
  `evictions` list is the **preview shown before any eviction** — LRU by `lastPerformedAt`,
  protected crates (the crate being prepared, crates backing a loaded deck) never candidates,
  `fits` honest when even full eviction can't close the gap.
- `Stems/StemService.swift` — the **§36.3 actor lane**: `planPreparation` (the preview),
  `evict(crateID:)` (removes the cache sets + marks the crate's tracks `evicted`),
  **`runCrateLane`** (budget → evict LRU crates to make room → serialize the pending tracks;
  pauses under the FR-ANL-2 performing fence, **abandons the instant the `.stems` governor
  lane is shed** §43.7 — a mid-run flip leaves the rest `pending`; per track `running` →
  decode → separate → cache.store → `ready` + bytes in one transaction, a real failure →
  `failed`, **model absence → stays `pending`**, never a fake failure), and `separateOnDemand`
  (§36.5, best-effort, cached so the next load is instant, never blocks the deck). Newest-1
  `observeProgress()` stream + `StemProgress`.
- `Features/GigCrate/GigCrateModel.swift` + `GigCrateView.swift` (mockup `ipad/14`): the crate
  list, the four header stat cards (audio cached / analyzed / stems separated / storage for
  this crate), the governor panel, the track table (stems-state pill, FR-LIB-8 Local/Caching
  pill), the amber **"One track can't go on a deck yet"** FR-LIB-8 notice, and the **"Making
  room" card that shows the eviction preview before any eviction** (§41.17, decision 11).
- Tests: 7 `GigCrateTests` + 11 `StorageBudgetTests` + 10 `StemServiceTests` + 5
  `GigCrateModelTests` — promotion order + honest FR-LIB-8 (no-asset / deleted-file),
  roll-ups, LRU ordering, **the lane evicting the LRU crate to make room** (real cache rows
  removed, `evicted` marked, budget reclaimed), mid-run abandonment, the performing fence,
  on-demand caching. Suite 1340 → **1373 green** (8 skipped); Swift 6 guard OK; app builds
  (xcodebuild verified); smoke tests pass in the pre-commit hook. DJ-only — no `xcodegen
  generate` (decision 25). **FR-PLIST-9, FR-ANL-9, FR-LIB-8, §41.17, §43.6, AT-STEM-\*.**

**M5 commit 5.10 — the record tap + encoder + segmented M4A — complete (`1f07de9`).**
The §37.2 recording path and the milestone's record toggle (plan decision 14, FR-ENG-7):

- `Recording/RecordTap.swift` — the **RT-safe, post-limiter master-bus copy** (§37.2): a
  pre-allocated lock-free SPSC ring the render closures write into **after** the limiter —
  what the audience hears is exactly what the recording captures. `write` copies and nothing
  else (no encode, no I/O, no allocation, no locks); **idle unless recording**
  (`setRecording` gates the copy, so a graph built with `recordTapEnabled: true` but not
  recording is still bit-exact — the reader harness). **When the ring is full it drops the
  incoming block and counts it** — "the ring absorbs a dropped drain": a slow encoder costs
  the tail of the recording, never the live performance.
- `Recording/RecordingEncoder.swift` — the **off-RT encoder actor**: drains the ring, writes
  AAC 256 kbps into a **segmented M4A** (`segment-NNN.m4a`, each a complete playable file —
  periodic flush so a crash or interruption costs at most the in-flight segment, NFR-REL-2);
  `finalize()` closes the final segment and returns `RecordingOutput` (segment URLs, total
  frames, sample rate, `format = "m4a-aac-256"` — the FR-REC-7 honest name). `drain`/`start`/
  `flushSegment`/`finalize` are the whole §37.2 state machine, deterministic on any host.
- `AudioGraph.Configuration.recordTapEnabled` **defaults to false** — the frame-exact reader
  harness never constructs a tap at all and stays bit-exact; the graph copies the
  post-limiter master into the tap when enabled (read-only on the signal, §37.2).
- `PerformanceEngine.startRecording` / `stopRecording` — creates the per-session directory
  under `DJDatabase.mixesDirectory`, starts the tap + encoder + an off-RT drain loop, stops
  and finalizes; a graph with no tap is the honest `tapNotRecording` state, never a silent
  no-op. `DJDatabase.mixesDirectory` is **user content, never a cache**: Application Support,
  **not** backup-excluded, `mixesEvictable = false` always (§43.6).
- **Workspace record toggle (decision 14):** `WorkspaceModel` mirrors `isRecording` +
  `recordingElapsed` (elapsed = `(masterSample − start) / sampleRate` — the recorded frames
  are exactly the tap's frames, §37.2) as shared session VM state; the mixer column's
  `recordControl` chip (mockup `ipad/07`'s "■ Stop & save · 00:18:42") carries the
  `dj.transport.record` identifier the regression suite drives (§53.11, dj-regression-suite.md
  hook 5.10). The retained `AudioSessionCoordinator` responses are consumed by the
  recording/service commits (5.10/5.11).
- Tests: 7 `RecordTapTests` (tap → drain matches the rendered master **bit-exact**; an idle
  tap leaves the reader bit-exact; the tiny ring absorbs a dropped drain — the render never
  blocks and stays correct, overflow counted; encoder finalize → a **playable** segmented M4A
  whose decoded duration + dominant frequency match; segment flush on budget; engine
  start/stop; the honest no-tap refusal) + 3 `WorkspaceModelTests` (toggle forwards, single
  toggle never restarts, elapsed tracks the master clock and freezes on stop). Suite 1373 →
  **1383 green** (8 skipped); Swift 6 guard OK; app builds; smoke tests pass in the
  pre-commit hook. DJ-only — no `xcodegen generate` (decision 25). **FR-ENG-7, §37.2,
  decision 14, dj.transport.record.**

**M5 commit 5.11 — the recording journal + crash/interruption recovery + finalize — complete
(`c83fd84`).** The §37.3 journal, the §34A.4 interruption path, and §37.5's single-file
finalize (FR-REC-1/3, NFR-REL-2, FR-ENG-8):

- **`Recording/RecordingService.swift`** — the §37.3 side-car actor. `begin(outputDirectory:)`
  writes the in-progress journal the moment recording starts (`mix.localState = recording` +
  `mix_asset.localRelPath = <sessionUUID>/mix.m4a`, one transaction, NFR-REL-1) so a crash
  leaves a recoverable row behind. `finalize(output:journal:)` **joins the segments into the
  single `mix.m4a`** (§37.5 step 1), promotes the rows to `complete` with the real
  duration/size, deletes the intermediate segments, and — **only under `-uiRegression`** —
  exports `mix-journal.json` beside the M4A carrying the engine configuration in force
  (limiter ceiling, master BPM, echo division, sample rate — the self-describing hook the
  regression suite's analyzer reads, dj-regression-suite §7 hook 5.11). **`reconcile()` on
  workspace appear** (NFR-REL-2, §37.3): every stale `recording` row whose flushed segments
  join is salvaged to `complete`; one with nothing recoverable is marked **`corrupt`** — a
  crash loses at most the in-flight segment, and it is never silently dropped (§46.2).
- **`Recording/M4AJoiner.swift`** — concatenates the encoder's segment M4As into one playable
  `mix.m4a` (the same `AVAudioFile` PCM→AAC path the encoder uses, deterministic on any
  host). A segment that is absent/empty/undecodable is **skipped, not fatal** — that is the
  crashed in-flight segment the journal is built around. `probeFormat` lets reconcile join
  without the engine's metadata.
- **`Recording/RecordingEncoder.swift`** — the §34A.4 interruption state machine:
  `interruptSegment()` drains whatever pre-interruption audio is still in the ring, closes
  the current segment as a **complete playable M4A** (the critical line behind NFR-REL-2) and
  **waits** (`drain` returns 0 while interrupted); `resumeSegment()` opens a **fresh** segment,
  never the flushed one. `RecordingOutput` gains `channelCount` (the joiner needs it).
- **`PerformanceEngine`** — `startRecording()` returns the per-session output directory (the
  journal derives the asset path from it); `interruptRecordingForInterruption()` /
  `resumeRecordingFromInterruption()` forward to the encoder (no-ops when not recording).
- **`WorkspaceModel`** — consumes the retained `AudioSessionCoordinator.responses` (the
  "consumed by the recording/service commits" from 5.4a): `.began` flushes the recording
  segment, `.ended` opens a new one, **never auto-playing** (§34A.4). `startRecording`/
  `stopRecording` write the journal (a journal failure aborts the recording rather than
  running journal-less); `reconcileRecordings()` runs on workspace appear; the journal JSON's
  engine configuration is assembled at stop. `DJEntryModel.makeModel` wires the real
  `RecordingService` (detecting `-uiRegression`).
- **Schema records** — `DJMix`/`DJMixAsset`/`DJMixTrackEvent`/`DJPerformanceSession` +
  `MixLocalState` (`recording|complete|corrupt`) in `DJRecords.swift`; `DJMixTrackEvent` is
  5.12's timeline row (the §7 journal's shape), present now so the schema is complete.
- Tests: 9 `RecordingRecoveryTests` (journal begin/finalize state machine against a real
  store over a temp pool; **finalize joins real segments into a playable `mix.m4a`** whose
  duration matches and deletes the intermediates; the `-uiRegression` JSON round-trip and its
  absence otherwise; **reconcile salvages a crashed recording** from its flushed segments —
  the removed in-flight segment is the NFR-REL-2 loss — salvages an already-joined M4A when
  only it survives, marks corrupt when nothing recoverable, no-ops when nothing is stale; the
  encoder's interrupt→wait→resume-into-a-new-segment state machine; finalize without begin is
  the honest error) + 5 `WorkspaceModelTests` (start/stop write the journal, a journal failure
  aborts honestly, the `.began`/`.ended` flush/resume forwarding, **interruption never
  auto-plays**, reconcile forwards). Suite 1383 → **1397 green** (8 skipped); Swift 6 guard
  OK; app builds (xcodebuild verified); iPhone + watch smoke pass in the pre-commit hook.
  DJ-only — no `xcodegen generate` (decision 25). **FR-REC-1/3, FR-ENG-8, NFR-REL-2, §37.3,
  §37.5, §34A.4, mix-journal.json hook.**

**M5 commit 5.12 — Finish + Mixes + timeline + the review listen — complete (`4cbbf04`).**
The §37.4 timeline, the §41.11 finish screen, and the §41.12 mixes library (FR-REC-1/4/5/6/7,
§18A.5 — **AT-REC-***):

- **`Recording/MixTimeline.swift`** — the §37.4 pure value: `MixTimelineEntry`
  (trackID/deck/startOffsetSec) + `MixTimeline` (ordered entries, a 10 s same-deck same-track
  pause/blip suppression so a genuine replay still logs). **Decision 8 satisfied control-side:**
  `WorkspaceModel` logs a deck's not-playing → playing edge while recording — offset is the tap's
  own master frames (§37.2), and a deck already playing at record time logs its track at ~0:00
  (mockup `ipad/09`'s "0:00 … opened"). `RecordingJournaling.finalize` gains `timeline:` and
  **returns the finished `DJMix`**: `RecordingService` resolves each track's title/artist/BPM/key
  snapshot from the store and writes the `mix_track_event` rows + `trackCount` in the journal's
  **one** transaction (NFR-REL-1; DELETE-then-INSERT so re-finalize is idempotent). Reconcile
  salvages with `events: []` — a crash lost the in-memory timeline; the audio is the NFR-REL-2
  point, the tracklist is not.
- **`Data/MixRepository.swift`** — the `MixServicing` seam + `MixRepository` over the single-writer
  store + `DJDatabase.mixesDirectory`: `completedMixes()` (complete + honestly-corrupt, newest
  first — §46.2's never-silently-dropped), `mixTrackEvents`, `mixAssetURL` (row-without-file =
  absence, never corruption), `updateMix` (FR-REC-1), `deleteMix` (row + the session directory's
  file — recordings are user content, §43.6), `mixStorageBytes` (the §41.12 storage readout).
- **The review listen (FR-REC-6)** — `Recording/MixPlayback.swift`: the `MixPlayback` seam + an
  `AVAudioPlayerMixPlayer` (settable `currentTime` = seekable), `MixWaveformModel` +
  `MixWaveformAccumulator` (the pure streaming peak kernel — O(bins) memory, so a 20-minute mix is
  never buffered for an overview) + `MixWaveformBuilder` (AVAudioFile streaming decode of the M4A).
- **`RecordingFinishModel`/`RecordingFinishView`** (mockup `ipad/09`): title/notes (FR-REC-1),
  the pills (duration, **M4A · AAC 256 kbps** — FR-REC-7 honesty, size, kHz/stereo), the review
  listen (transport + seekable waveform with **green tappable transition markers** from the
  timeline), the timeline table, attribution (§18A.5 — per-track "Artist — Title" + the CC licence
  line, carried to the cue-sheet), export (Save to Files via `fileExporter`, Share via `ShareLink`
  with the optional cue-sheet, FR-REC-4), honest corrupt/absence states, and Delete. The sheet is
  presented from `model.finishedMix` on the iPad workspace **and** the compact surfaces the moment a
  recording finalises.
- **`Features/Mixes/`** (mockup `ipad/10`): the **free, un-gated** `MixesView` (FR-REC-5) — cards
  (title/date/duration/tracks/size/state), the storage + playback cards, the empty state, delete,
  and replay through the finish screen. Reachability: `DJDestination.mixes` added to the route
  table (§49.3a) + the app-root `DJHomeView` row (`dj.mixes`).
- Tests: 7 `MixTimelineTests` (suppression, replay, per-deck, cue-sheet golden, timestamp, the
  accumulator's bins/non-integral/empty, a real file decode) + 7 `MixRepositoryTests` (ordering,
  corrupt honesty, events order, update, asset resolve/absence, **delete removes row + file +
  cascaded rows**, storage sum) + 10 `RecordingFinishModelTests` (load, honest absence, corrupt
  never plays, transport forwarding, tick, save, delete, attribution, cue-sheet, share items) + 3
  `MixesModelTests` + 3 `WorkspaceModelTests` (playing-edge capture, already-playing-at-record,
  finishedMix surfaced + dismissed) + 2 `RecordingRecoveryTests` (timeline rows with resolved
  snapshots, replace-on-refinalize) + `DJEntryTests` updated. Suite 1397 → **1433 green** (8
  skipped); Swift 6 guard OK; app builds (xcodebuild verified); iPhone + watch smoke pass in the
  pre-commit hook. DJ-only — no `xcodegen generate` (decision 25; the app-side `DJHomeView` edit is
  an existing file). **FR-REC-1/4/5/6/7, §37.4, §41.11, §41.12, §18A.5, AT-REC-\*.**
  *Recorded deviation: the DJ schema carries licence at the source level (the 5.6 deviation — no
  per-track licence/source link), so §18A.5's attribution ships as per-track artist credits on the
  finish screen + cue-sheet with the uniform CC licence line stated once; and the timeline logs
  track starts (the `mix_track_event` shape), not every cue/loop/crossfader move.*

**M4 commit 4.13 — paywall + purchase flow + memory ceiling — complete (`01d4acb`).**
The 3.0 Pro launch's closing surface (plan 4.13, §2.1/§2.10, §43.5) — **M4 is
now complete**: every commit 4.1–4.13 is on `main`, and the milestone's ship
gates (AT-THERM-1, AT-MEM-1, AT-PLIST-2/7) are the user-owned post-M4 device pass:

- `Pro/EntitlementStore.swift` — `EntitlementSource` gains `purchase()`/`restore()`
  (default no-ops, so the read-only fakes in other suites need no change);
  `StoreKitEntitlementSource.purchase()` buys `guru.parso.tonearm.pro` via
  `Product.purchase()`, `restore()` = `AppStore.sync()`. `EntitlementStore` gains
  `purchase()`/`restore()` that re-derive from `currentEntitlements`, so **`isPro`
  flips in-process with no relaunch** (AT-STORE-2, FR-STORE-1/2/3). `Source` docs
  corrected (`.purchased` = "bought guru.parso.tonearm.pro"; `.foundersGrant`
  survives only as a legacy cache row).
- `Pro/FoundersGrant.swift` — the **product repurpose** (§2.1): `FoundersGrant`
  collapses to the single `guru.parso.tonearm.pro` (the repurposed DJ product —
  no `.pro.dj`, no retired product). The T.4 table becomes **one row**: verified
  ownership ⇒ `.purchased`, family-shared ⇒ `.familyShared`, revoked ⇒ none; an
  unverified transaction never grants. `FoundersGrantTests` rewritten to that
  table (AT-STORE-4).
- `Features/Paywall/PaywallModel.swift` — the §41.16/§42.10 model (mockups
  `ipad/13a`, `ipad/13b`, `iphone/08`): consumes `isPro` and calls `purchase()`/
  `restore()`, **never imports StoreKit** (App. T.3, §6.3). Presentation is
  contextual-only — `present()` is the sheet's only entry, called from the lock
  chip (§40.4 rule 3, FR-STORE-5); a dismissal is final for the session
  (FR-STORE-6, T.7); a verified purchase auto-dismisses the sheet, a failed one
  keeps it up with an honest message; `displayPrice` pinned to the storekit's
  $39.99. `Features/Paywall/PaywallView.swift` — the sheet: one-time price,
  the §2.4 green "everything you have now stays free" panel (naming the CI
  test), GPLv3 build-it-yourself note, visible Restore, `isPurchasing` buy
  button; no countdown/strikethrough/scarcity, no trial (plan §2.10). The lock
  chip on **all three** performance surfaces (`WorkspaceView`, `SoloDeckView`,
  `TwinDeckView`) now presents the sheet; `WorkspaceModel.store` is exposed so
  the paywall buys through the same store that unlocks the decks.
- `Perf/MemoryCeiling.swift` (§43.5, NFR-REL-4) — the pure policy (device class
  from total RAM; ceilings 1.4 / 1.0 / 2.0 GB per class; **80% shed** / **95%
  refuse-load** bands; the §43.5 shed order — waveform LODs → non-focused deck's
  cached stem tails → on-demand separation → analysis), a Darwin
  `task_vm_info.phys_footprint` provider (no `#if os`, the engine-core rule),
  and a `MemoryCeilingMonitor` that samples every 2 s + on deck load and refuses
  the next load at 95% with an honest message. **AT-MEM-1 is the user-owned
  on-device gate** (deferred, plan §2.11); these policy tests are its automated
  proxy.
- Tests: 8 `PaywallModelTests` (contextual presentation, Pro no-op, purchase
  flips without relaunch, failed purchase keeps the sheet + honest message,
  restore, no-nagging dismissal, explicit re-reach still shows) + 15
  `MemoryCeilingTests` (ceilings per class, 80%/95% bands, shed order,
  refuse-at-95% with message, probe failure keeps the baseline) + the
  purchase/restore path in `EntitlementStoreTests` + the one-row
  `FoundersGrantTests`. Full suite **1224 green** (1201 baseline + 23); Swift 6
  guard OK; StoreKit boundary intact (only `Sources/Pro/` imports StoreKit); no
  `xcodegen generate`. **FR-STORE-1/2/3/5/6/7, AT-STORE-2/4, NFR-REL-4; M4
  complete — AT-ENGINE-\*, AT-SESS-\*, AT-STORE-\*, AT-TWIN-\* green.**

**M4 commit 4.12 — Track Prep + grid corrections — complete (`ea66d33`).**
The §41.8 Track Prep surface over the existing `grid_correction` path — the
authoritative override log that replays deterministically over the immutable
detected grid (§23.3, FR-PREP-5, FR-ANL-5, AT-GRID-\*):

- `Data/GridCorrectionRepository.swift` — `TrackPrepSnapshot` (identity + the
  **free** analysis readout per FR-PREP-4: BPM/key/LUFS/DR/grid confidence,
  phrase map, first downbeat) and the authoritative `DeckGrid` a deck would
  load (detected `beat_grid` + replayed corrections); `GridCorrectionRepository`
  over the pool + the `DJLibraryStore` actor (reads via the pool, writes
  through the single writer), plus the `TrackPrepRepositing` seam so the VM
  tests inject a fake repository.
- `Domain/DJLibraryStore.swift` — `gridCorrections` / `appendGridCorrection` /
  `undoLastGridCorrection`, each one GRDB transaction (NFR-REL-1).
- `Engine/DeckClock.swift` — `GridReplay`, the pure §23.3 kernel next to
  `DeckGrid`: nudge/shift add a sample delta, setDownbeat/setBPM are absolute
  (the newest wins), ×2/÷2 scale tempo, malformed entries skipped, replay
  ordered by `(appliedAt, id)` so array order can never matter (NFR-DET).
  `authoritativeGridIfAnalyzed` reports the honest "no grid yet" state — a
  correction without a grid to correct is meaningless.
- `Features/Prep/TrackPrepModel.swift` — the gate
  (`ProCapability.isEnabled(.preparation)`, App. T.3 — free users see the
  readout only, the tools render locked per §40.4) + the one-thumb tools
  (nudge, tap-to-set-downbeat, ×2/÷2, setBPM, undo) that append to the log
  and re-read the snapshot, plus the pure `TempoTapper` — a median-interval
  tempo tap robust to one mistimed tap (FR-PREP-5).
- `Features/Prep/TrackPrepView.swift` — mockup `ipad/06`: readout pills, the
  gated grid-tool chips, a waveform with **real pinch-zoom over the grid's
  bar/beat markers** (honest baseline bars until the analysis-driven pyramid
  render, per the 4.6/4.7 convention), drag-to-nudge / tap-to-set-downbeat
  committing **once** on release with haptic confirm (NFR-A11Y-3), and the
  free "What we heard" panel. Cue pads and loops render the honest
  unavailable state until their repositories land (the FR-PREP-2/3
  convention, like the stems faders before M5).
- Tests: 18 `GridCorrectionTests` — replay golden + determinism +
  malformed-skip + nil-base; **DB tests assert a correction overrides
  without mutating `beat_grid` (bpm/source/firstBeatSample untouched),
  persists across a fresh repository, and feeds the deck grid; undo pops the
  newest only**; the readout rows (LUFS/DR/phrases/confidence); the VM gate
  refuses free edits at the intent boundary and forwards Pro ones through the
  fake; TempoTapper math. Full suite 1201 green (1183 baseline + 18); Swift 6
  guard OK; no `xcodegen generate`. **FR-PREP (grid), AT-GRID-\*, FR-ANL-5,
  §23.3.**

**M4 commit 4.11 — iPad deck module slot, default `STEMS` — complete (`726884a`).**
The §41.9a per-deck module slot (mockup `ipad/07b`, FR-ENG-1 — jog as a slot,
AT-TWIN-2 — a module never occludes shared controls):

- `Features/Workspace/DeckModuleSlot.swift` — the per-deck slot: a
  `JOG · STEMS · PADS · FX` seg over the module content. STEMS (the default)
  = the four honest-unavailable stem faders until M5 (plan §2.6); PADS = the
  four pads; FX = honest-unavailable FX pads. **A module is a layout member
  of its own deck column, never an overlay** — swapping modules changes no
  engine state and structurally cannot reach the mixer column, either
  waveform, the beat-phase meter or the opposite deck (AT-TWIN-2).
- **JOG module** — the §41.9a **248 pt** jog flanked by ± pitch-bend buttons
  (a momentary 0.4% bend routed through the jog's own `.nudge`/`.release`,
  so a button bend is byte-for-byte a ring bend), the vinyl/CDJ platter
  action selectable above and **shown inside the platter** so the mode is
  never a guess. `JogGestureModel` gains `JogMode` (vinyl = scratch / CDJ =
  nudge — a CDJ platter rotation emits `.nudge`, not `.scrub`, §40.7.3) and
  `setSensitivity` (clamped to §40.7.4's 0.5–2.0); `JogView` gains
  `mode`/`sensitivity`/`showsModeReadout` params (phone surfaces unchanged
  via defaults), the iPad hub rendering the mode pill + BPM + a pure
  `barBeat` bar/beat readout (§40.7.4's iPad compensation for no Taptic
  engine).
- `WorkspaceModel` — `DeckModuleSlot` + per-deck jog mode/sensitivity state;
  the slot and mode **persist per deck** through injectable `UserDefaults`
  (default `STEMS` / vinyl, §41.9a's "remembered per deck"), plus
  `ModuleGeometry` (jog 248 + bend columns; `jogModuleWidth` fits the §41.9
  `1fr 268px 1fr` deck column on the 1180 canvas). `WorkspaceView` — the deck
  column's lower third is the module slot, LOOP is now the release-to-commit
  flyout identical to the compact idiom (§42.7b idiom 3), and the mixer
  column gains the per-deck jog-sensitivity faders.
- Tests: 6 `WorkspaceModelTests` (default `STEMS`, per-deck slot + jog-mode
  persistence across model instances, module/mode/sensitivity swap changes
  **no** engine state, sensitivity clamps, `jogModuleWidth` fits the deck
  column) + 6 `JogGestureModelTests` (vinyl default, CDJ platter nudges not
  scratches, ring still bends in CDJ, nudge saturation, `setSensitivity`
  clamp, `barBeat` golden). Full suite 1183 green (1171 baseline + 12);
  Swift 6 guard OK; no `xcodegen generate`. **FR-ENG-1, AT-TWIN-2, §41.9a.**

**M4 commit 4.10 — bank drawers, edge sliders, bottom-edge crossfader — complete (`f9e77c9`).**
The five §42.7b modal idioms with their two normative rules over the one
`WorkspaceModel` (mockup `iphone/05d`, FR-ENG-12, AT-TWIN-2/3/4):

- `Features/Workspace/BankDrawer.swift` — the **momentary bank drawer**: a
  228×206 panel over **one deck's jog + transport and nothing else**
  (`EQ · STEMS · PADS · CUES` seg — EQ = three 44 pt knobs with kill/boost
  readouts + a TRIM fader, STEMS = **two** honest-unavailable stem faders per
  §2.1's iPhone budget, PADS = four 44 pt pads, CUES = four hot cues), a grab
  handle + pinned-drawer dismiss button. **Spring-loading** (AT-TWIN-3): press
  springs, release dismisses within one frame — a held drawer can never leave
  the surface in a forgotten mode — a tap pins, and the pinned drawer
  self-dismisses after 12 s idle (injectable) with touch resetting the clock.
  The state machine lives in `WorkspaceModel` (`TwinBank`, `DrawerState`
  idle/spring/pinned, `springDrawer`/`releaseDrawer`/`pinDrawer`/
  `dismissDrawer`/`selectDrawerBank`/`noteDrawerActivity`) — **view-only**, no
  engine call, decks keep playing under the drawer.
- **Release-to-commit LOOP flyout** (`LoopReleaseToCommitButton`): holding LOOP
  raises the §41.9a beat counts 1/2/4/8/16/32 + EXIT; release over a chip
  commits, release outside cancels — the loop never changes on the way out.
  The chips are positioned at the model's pure `WorkspaceModel.LoopFlyout`
  frames, so the drag's release resolution is honest to what the user sees;
  the flyout stays within that deck's column. **Decision (recorded):** CUE
  keeps its existing §33.1 press-jump-preview / release-return — the same
  idiom's cue semantics — rather than a second flyout with invented engine
  calls.
- **Bottom-edge crossfader** (`BottomEdgeCrossfader`): the §42.7a full-width
  40 pt **1:1 relative** drag surface over the vertical slack + home indicator
  (pure `WorkspaceModel.relativeCrossfader`, double-tap slams); the surface
  gains `.ignoresSafeArea()` so the §42.7a canvas (852×393) and the band land
  exactly.
- **Screen-edge filter slider** (`EdgeSlider.swift`, rule 2): 24 pt at the
  true screen edge, always live and never occluded — the drawer's frame
  (dead band 59 + margin 30 + one deck column) structurally clears it.
- The bank tab's 44 pt hit region is a bottom-aligned overlay overlapping the
  jog's lower rim per §42.7a, without breaking the 206 pt control band.
- Tests: 12 new `WorkspaceModelTests` — spring-release restores the jog in one
  frame, pinned drawer self-dismisses after idle (and does **not** before),
  touch inside the pinned drawer resets the clock, the spring-release-pins
  threshold, the drawer never covers the shared controls across both decks
  (`drawerXRange` vs `mixerXRange` never intersect) + the edge-slider
  clearance, drawer interaction changes no engine state, springing one deck
  replaces another's pinned drawer, per-deck bank memory, flyout release
  resolution golden incl. the cancel paths, and the 1:1 relative-crossfader
  mapping. Full suite 1171 green (1159 baseline + 12); Swift 6 guard OK; no
  `xcodegen generate`. **FR-ENG-12, AT-TWIN-2/3/4, §42.7b.**
- **Seed-fix (`1290b31`):** the documented `OnsetTests` flake is fixed — the
  noise test now uses the repo's seeded `SplitMix64` (which gains the
  `RandomNumberGenerator` conformance) instead of ambient entropy, so
  `peaks.count < 3` is deterministic (NFR-DET-3). It blocked the 4.10 commit
  twice before the fix.

- **M4 commit 4.9 — `TwinDeckView` + orientation switch — complete (`113e8b7`).**
The landscape twin-deck surface and §42.1's posture switch (FR-ENG-10, AT-TWIN-1):

- `Features/Workspace/TwinDeckView.swift` — `TwinDeckView`, the §42.7a
  landscape surface (mockup `iphone/05c`): 168 pt `JogView` per deck
  (transport on each deck's inner side — CUE · PLAY/PAUSE · LOOP 54×54, jog
  intents through a lazily-created `JogTransport` per deck, AT-TWIN-4),
  stacked waveforms on **one shared playhead** (the beat ticks are positioned
  from each deck's telemetry phase, so a synced pair shows coincident grids —
  the honest baseline until the deck-prep waveform render), the 202 pt mixer
  column (signed beat-phase meter + "locked · ±ms" readout, channel faders
  A/B, SYNC tap=beat/hold=downbeat, crossfader — **no EQ**, it is a bank), a
  passive bank tab per deck (the §42.7b drawer is 4.10), and a continuous
  screen-edge filter slider on each edge that costs zero layout width and is
  never occluded. The layout consumes `WorkspaceModel.TwinGeometry` — §42.7a's
  budget verbatim (`734 = 30 │ 168 │ 6 │ 54 │ 8 │ 202 │ 8 │ 54 │ 6 │ 168 │
  30`); the 59 pt sensor-housing dead bands carry nothing interactive.
- **Orientation switch:** `CompactPerformanceView` maps `verticalSizeClass`
  (`.compact` = landscape = twin, `.regular` = portrait = solo) onto the
  model's view-only `compactPosture` and renders `SoloDeckView`/`TwinDeckView`
  over the **one** `WorkspaceModel`. The container owns the engine lifecycle
  (begin/end, scene-phase pump, `.defersSystemGestures`), so rotating never
  stop/starts the engine — `SoloDeckView` gains a `managesLifecycle` flag
  (default true; false when embedded) to make that possible.
- `WorkspaceModel` additions: `channelA`/`channelB` published fader state
  (unity default, the §35.4 transparent-until-touched convention),
  `compactPosture` + `setPosture` (view-only), the pure
  `beatPhaseError`/`beatPhaseErrorMillis` (signed circular difference;
  `ms = error × 60000/bpm` — the sample rate cancels), and `TwinGeometry`.
- Tests: 6 new `WorkspaceModelTests` — rotation is view-only, rotation
  preserves transport/playhead exactly (AT-TWIN-1), channel-fader state
  mirrors the engine, golden phase-error + ms math, the §42.7a budget sums to
  734 and a deck column decomposes exactly. Full suite 1159 green (1153
  baseline + 6); Swift 6 guard OK; no `xcodegen generate`. **FR-ENG-10,
  AT-TWIN-1, §42.1/42.7a.**

- **M4 commit 4.8 — `JogGestureModel` (pure) + `JogView` — complete (`fce2b16`).**
The §40.7 jog control model, the rendered platter, and the jog's only route to
the transport (FR-ENG-11, AT-TWIN-4):

- `Features/Workspace/JogGestureModel.swift` — the **pure** contact-relative
  rotation state machine (§40.7.2–40.7.4): no SwiftUI/UIKit/engine reference.
  Rotation is measured from wherever the finger lands; the radius split
  (platter inner 58% / ring outer 42%) is **fixed at touch-down** — a drag that
  crosses the boundary mid-gesture must not change mode; sensitivity 0.5–2.0
  (clamped) scales displacement; the ring's bend saturates at ±16% across ±π.
  Emits **only** the four transport intents `hold` / `scrub(radians:)` /
  `nudge(rate:)` / `release`. `JogPoint` (Double coords) keeps it host-agnostic.
- `Features/Workspace/JogView.swift` — the rendered platter off the telemetry
  pump (the model's `@Published telemetry`, driven at display cadence by
  `TelemetryPump` — no second display link): the **position marker** (this
  deck's beat phase) + the **phase ghost** (the other deck's beat phase) on the
  same dial (§40.7.5), a hub readout, and `JogDetentDriver` — Core-Haptics
  light-per-beat / heavy-per-downbeat detents (§40.7.4) while the platter is
  held, following the master clock (the audible beat while a held deck pauses).
  `JogTransport` maps the intents onto the engine's existing transport intents
  (pause/play hold-resume, relative seek — one revolution = one beat,
  setRate bend off the deck's base) and is guarded by `RTGuard.assertRTSafe`
  (§46.3). **Decision (recorded):** the spec's App. I.4 façade does **not**
  actually define `scrub/nudge/hold/release` (the claim in FR-ENG-11/§40.7.7 is
  aspirational in the spec itself), so `JogTransport` maps the four jog intents
  onto the transport surface the engine already ships, documented in the file;
  `WorkspaceEngine`/`WorkspaceModel`/`PerformanceEngine` gain the read-only
  `deckRate(_:)` seam (graph already publishes it) as the pitch-bend base.
- The 4.7 solo-deck `Jog` bank chip swaps the placeholder circle for the real
  `JogView` (168 pt), wired through a lazily-created `JogTransport`.
- Tests: 21 `JogGestureModelTests` — rotation→scrub/nudge, the radius split
  fixed across a boundary-crossing drag (both directions), sensitivity scaling
  + clamping, contact-relative displacement, release, a golden deterministic
  script, bend saturation, one-beat-per-revolution scrub math, the detent
  driver's pure per-beat/per-downbeat decision, **AT-TWIN-4** (the jog's
  intent path is flagged by the §46.3 shim inside `withRenderContext`), and
  FR-ENG-11 transport wiring (hold pauses + release resumes a playing deck, a
  paused deck is never started by lift, scrub seeks relative and clamps at 0,
  nudge bends off the base and release restores, non-unity base rate).
  Full suite 1153 green (1132 baseline + 21). **FR-ENG-11, AT-TWIN-4, §40.7.**

- **M4 commit 4.7 — iPhone portrait solo-deck surface — complete (`91580c0`).**
The §42.6–42.7 compact posture over the shared `WorkspaceModel` (mockups
`iphone/05a`, `iphone/05b`):

- `Features/Workspace/SoloDeckView.swift` — one focused deck full-width
  (header pills, playhead + BPM readout, waveform, CUE/PLAY/SYNC/LOOP
  transport, hot-cue pads, bank chips `Stems · EQ · Filter · Cues · Jog`),
  the other deck in a **72 pt strip** (identity, BPM, state, playhead,
  play/pause); **swipe-up or tap swaps focus — view-only**, both decks stay
  live in the engine, no engine state changes (FR-ENG-10, §42.1). The
  crossfader lives in the **always-visible bottom bar** (the whole strip is a
  1:1 relative drag surface) and the browse-while-performing crate sheet may
  never cover it: the sheet renders *behind* the bar and its height is bounded
  by the model's pure `WorkspaceModel.crateSheetMaxHeight` rule. 44 pt min
  targets, haptic confirm via the new `Features/Common/Haptics.swift`
  (NFR-A11Y-3). Free users see the real dimmed surface + lock chip (§40.4).
- `WorkspaceModel` gains the compact-posture state — `focusedDeck` +
  `swapFocus` (no engine call), `isCrateSheetPresented` raise/dismiss, and the
  static `crossfaderBarHeight`/`crateSheetMaxHeight` geometry bound.
  `WorkspaceEngine` gains `sampleRate` so playheads render as clock time; the
  iPad workspace's `TransportButton`/`Pill`/`EQGroup`/`EQKnob`/`VerticalSlider`
  are shared across both surfaces (promoted to internal).
- Tests: 3 new `WorkspaceModelTests` — focus swap is view-only (engine records
  zero calls, telemetry untouched), the sheet never covers the crossfader over
  a spread of container heights, raising the sheet changes no engine state.
  Full suite 1132 green (1129 baseline + 3). Swift 6 guard OK. No
  `xcodegen generate`. **FR-ENG-9/10, §42.6–42.7.**
- **Decision (recorded):** the crate-sheet track rows (gig crate ranked by the
  §28A.2 transition cost against the playing deck) and track titles/keys are
  deferred — the workspace has no library data seam yet — so the sheet carries
  the honest placeholder like the waveform/stems baselines; the normative
  geometry rule is what this commit ships.

- **M4 commit 4.6 — dual-deck sync + telemetry + iPad workspace — complete.** The
§32 sync engine, the §40.3 telemetry pipeline, and the single session VM over
the `ipad/07` workspace:

- `Engine/SyncEngine.swift` — the pure §32.3 kernel: `SyncClock` (playhead +
  grid + rate), `SyncCorrection`, and `correction`/`downbeatCorrection`/
  `continuousRate`. `DeckGrid` gains `beatPhase(at:)`/`barPhase(at:)`.
  `PerformanceEngine.sync/unsync`: the pure correction is applied as a rate
  command + a scheduled sample-accurate nudge (`RTCommand.syncNudge`), then
  `.sync` engages **continuous rate tracking** — the render thread re-derives
  the synced deck's rate every callback so a master pitch change moves the
  synced deck with it (§32.1).
- Telemetry: the graph publishes per-callback relaxed atomics — deck
  rate/level (peak measured in the deck chain and the post-limiter bus)/
  playing/synced, plus the `MasterClock` components (master sample, effective
  BPM, downbeat phase) — assembled by `AudioGraph.masterClock` (the §30.1
  snapshot). `EngineTelemetry` + `EngineTelemetryStream` (atomics →
  `AsyncStream`, newest-1); `PerformanceEngine.sampleTelemetry/pushTelemetry/
  telemetry`. `Features/Common/TelemetryPump.swift` — `CADisplayLink` (iOS) /
  `NSScreen.displayLink` (macOS test host), ProMotion 60–120 Hz, throttled to
  30 Hz at `.serious`, paused backgrounded.
- `Features/Workspace/` — `WorkspaceModel` (the one session VM over the
  `WorkspaceEngine` protocol, mixer control state, idle-timer scoping §34A.6
  driven from telemetry) + `WorkspaceView` (two decks, centre mixer: vertical
  EQ stacks, filter sliders, crossfader, master meter, limiter indicator,
  beat-phase meter, thermal/buffer readout; SYNC tap=beat/hold=downbeat),
  gated by `ProCapability.isEnabled(.decks)` — free users see the real dimmed
  surface + lock chip (§40.4). **Decision (recorded):** the `MasterClock`
  snapshot is three relaxed atomics assembled control-side (a ≤1-callback skew
  is harmless for a relative nudge + display-rate readouts), not a
  reverse-direction double-buffered pointer — the render thread cannot
  allocate/lock.
- Tests: 12 pure `SyncMathTests` + 4 new `EngineOfflineTests` (sync aligns
  beats on the master grid, continuous rate tracks a master pitch change then
  unsync freezes, bar sync aligns downbeats, telemetry/master-clock readouts
  exact) + 8 `WorkspaceModelTests` (gate, lifecycle, forwarding, the
  atomics→stream pipeline). Full suite 1129 green (1105 baseline + 24). No
  `xcodegen generate`. **FR-ENG-1/2/4, FR-ENG-9; AT-ENGINE-SYNC-\*.**

- **M4 commit 4.5 — time-stretch / key lock / key shift — complete (`c628e99`).**
The §31 time-pitch wiring, with a per-deck `AVAudioUnitTimePitch` in the graph
and a pure cent-math core:

- `Engine/TimePitch.swift` — `TimePitchMath` (pure `rateFromPercent`,
  `centsFromRate` = 1200·log2(r), `semitoneCents`,
  `pitchCents(rate:keyLock:keyShiftSemitones:)`), `TimePitchSettings` (per-deck
  rate/keyLock/keyShift → `unitPitchCents`, plus `effectiveKeyShiftSemitones`
  for the UI's Camelot hint), `TimePitchUnit` (`AVAudioUnitTimePitch` wrapper,
  music parameters — transient-preserving mode asserted, RT-safe `apply` that
  skips unchanged values so an idle deck costs no parameter traffic).
- `Engine/RTCommand.swift` — `setKeyLock`/`setKeyShift` tags; `DeckState`
  gains the keyLock/keyShift state; `PerformanceEngine` gains
  `setKeyLock`/`setKeyShift` on the same lock-free command path.
- `Engine/AudioGraph.swift` — `Configuration.timePitch` engages a §29.1-shape
  per-deck `source → unit → main mixer` topology (the offline pitch tier).
  Both deck source nodes drain the ring (first drain applies every command,
  second finds it empty) so application is independent of engine pull order;
  the master clock advances in `render()` so both decks read the same
  pre-advance `frameStart` within a callback. **Decision (recorded):** the deck
  reader stays the tempo authority (frame-exact, per the 4.4 decision) and the
  unit carries only the key compensation — `unitRate` held 1.0,
  `unitPitch` = (keyLock ? −1200·log2(rate) : 0) + 100·semitones — so every
  frame-exact reader test stays bit-exact while FR-ENG-6 holds observably
  (spike-verified: reader 528 Hz + unit −316¢ → 440 Hz).
- Tests: 8 pure `TimePitchTests` (golden cent conversions; keyLock holds,
  vinyl follows, semitone-ratio rules) + 6 new `EngineOfflineTests` on the
  time-pitch graph that measure the **dominant frequency by zero crossings**
  over a steady window (keyLock on at rate 1.2 holds 440 Hz; keyLock at unity
  transparent; keyLock off follows rate to 528 Hz; ±1 semitone at `2^(±1/12)`;
  keyShift compounds under keyLock to 440·2^(1/12), not 528·2^(1/12)). Full
  suite 1105 green. No `xcodegen generate`. **FR-ENG-6, AT-ENGINE-\*.**

- **M4 commit 4.4 — mixer: EQ / filter / crossfader / limiter — complete (`6e3c0e9`).**
The §35 mixer DSP, wired into the deck render path and the master bus:

- `Engine/Mixer.swift` — `LinkwitzRiley` (LR4: two cascaded 2nd-order Butterworth
  biquads per band; the low/high sum is an exact all-pass — flat magnitude at
  unity, phase-coherent kills), `ThreeBandEQ` (200 Hz / 2 kHz splits, smoothed
  gains, `knobToGain` maps −1 kill … 0 unity … +1 = +6 dB), `SweepFilter`
  (state-variable HP/LP, hard-bypassed at centre, 12 kHz → 300 Hz sweep),
  `crossfaderGains` + `CrossfaderCurve` (constantPower / linear / sharp, the
  spec's §35.4 function verbatim), `SmoothedGain` one-pole ramps so fader moves
  never click, `LookaheadLimiter` (delay-line lookahead, soft-knee gain that
  provably never exceeds the ceiling, instant attack / slow release), and the
  graph wiring `DeckMixer` (per-channel EQ→filter→fader→crossfader chain) +
  `MasterStage` (crossfader position/curve + per-channel limiter).
- `Engine/RTCommand.swift` — `setEQ`/`setFilter`/`setFader`/`setCrossfader` tags
  and an `f2` payload slot for the three band gains.
- `Engine/AudioGraph.swift` — each deck's chain runs per sample in `readChunk`;
  the master stage applies crossfader gains per deck each callback and the
  limiter over the summed bus. `Configuration` gains `limiterCeiling`/
  `limiterLookaheadFrames`.
- `Engine/PerformanceEngine.swift` — `setEQKnobs` (knob→gain), `setFilter`,
  `setChannelFader`, `setCrossfader` — all enqueue lock-free commands.
- Tests: 16 pure `MixerTests` (crossfader laws + power identity, smoothed gain,
  EQ magnitude-flat/kill/knob anchors, filter bypass/LP/HP/cutoff, limiter
  ceiling/lookahead/transient-prediction/brickwall) + 5 new `EngineOfflineTests`
  (EQ kill silences the graph, filter bypass frame-identical, fader halves the
  deck, constant-power crossfader blend at full-A/full-B/centre, master limiter
  clamps the graph output). Full suite 1091 green. No `xcodegen generate`.
  **Decisions:** the deck chain is a bit-exact pass-through until a control is
  touched (EQ idle until `setEQ`, filter bypassed at centre, crossfader idle
  until positioned) so the 4.3 frame-exact reader harness stays valid; the
  limiter is out of the path unless a ceiling is configured (reader harness
  runs without it, mixer tests configure it). **FR-ENG-2, FR-ENG-7 (master
  path), AT-ENGINE-\*.**

- **M4 commit 4.3 — single-deck play/cue/loop, sample-accurate — complete (`e595254`).**
The deck reader replaces the 4.1 sine scaffold (§29–30, §33), driven only through
the command ring:

- `Engine/DeckClock.swift` — `DeckClock` (absolute master sample, §30.1), `DeckGrid`
  (beat grid for quantize), `QuantizeResolution`, and `DeckSource` — a **pure-value**
  pre-decoded PCM source that crosses the RT boundary as a raw pointer: no ARC, no
  lock, no allocation (§12.3).
- `Engine/Scheduler.swift` — pure `quantizedBoundary(after:resolution:grid:)` and
  `triggerFrame(...)`: the exact master-timeline frame a trigger lands on (§30.3).
- `Engine/CueLoop.swift` — pure loop end/wrap math + the `TempCueState`
  press-jump-preview / release-return machine (§33).
- `Engine/AudioGraph.swift` — two `DeckState` readers over a zeroed baseline
  (both decks sum; paused/unloaded decks render **silence, not garbage**, and bump
  the §46.2 starved counter). Loop wrap and quantized cue jumps **split the buffer
  at the exact frame** (§30.2). Master clock + per-deck playheads publish via
  relaxed atomics (§30.1). `RTCommand` gained seek/setCue/cuePress/cueRelease/
  triggerHotCue/setLoop/exitLoop/setQuantize, an `i1` slot, and `setPitch` →
  `setRate` (§31.1).
- `Engine/PerformanceEngine.swift` — the `@MainActor` façade (App. I.4):
  `load/play/pause/cue/seek` + `setQuantize`, hot cues, CDJ-style loops — all
  enqueue lock-free commands, none block on audio. `load` boxes the `DeckSource`
  (the §12.2 ownership-transfer marker) and owns the box lifetime.
- `EngineOfflineTests` — 25 green on the macOS host: a hot cue lands on the exact
  frame; a loop wraps end→start frame-exact; a **quantized trigger lands on the
  grid boundary mid-buffer** (sample 24 000, split inside a 4096 chunk); playhead
  telemetry exact; temp-cue press/release returns to the pre-preview position;
  dual-deck sum + pause-freeze; no-buffer renders silence (§46.2); pure
  quantize/loop/cue math; 10 s render never overruns. **FR-ENG-1/5, AT-ENGINE-\***
  (offline-render tier; physical timing is user-owned — plan §2.11). Full suite
  1070 green; no `xcodegen generate` (DJ excluded from app target).

- **M4 commit 4.2 — `SessionPolicy` + `AudioSessionCoordinator` — complete
  (`40903e7`).** Pure §34A route/interruption decision table (mode buffers,
  granted round-trip, every §34A.3/34A.4 row, never-auto-play) + the thin
  `#if canImport(AVAudioSession)` coordinator shell (category→prefs→activate→
  read-back, Bluetooth refusal, media-services reset). 20 `AudioSessionMatrixTests`
  green. **FR-SESS-1/2/3/4, AT-SESS-\* decision matrix.**

- **M4 commit 4.1 — RT boundary + RTGuard + offline engine harness — complete
  (`211f431`).** `RTCommand` (POD, `@unchecked Sendable`) + `CommandRing` (fixed
  power-of-two SPSC, stdlib `Atomic<Int>` head/tail, release/acquire, never grows);
  `EngineSnapshot` (double-buffered `Atomic<UnsafeRawPointer?>` publish/read, control-side
  retire list); `RTGuard` (DEBUG thread-local render flag, RELEASE compiles out); `RenderLoad`
  (`mach_absolute_time`, one relaxed atomic store); `AudioGraph` (offline manual-rendering
  `AVAudioEngine` harness; render block captures ring/snapshot/load/probe/state, not `self`).
  `EngineOfflineTests`: 12 green — ring FIFO/full→false/empty/pointer round-trip; snapshot
  publish/read/retire; RTGuard flag + nested context; RenderLoad measure/reset; offline render
  vs sample-referenced sine; pause-mute + frozen-phase resume; **setPitch at exact frame 100
  (±5e-4)**; RTGuard wraps the render; 10 s/512-frame render with 21-command bursts renders
  every frame, bounded output, load < 1.0. **FR-ENG-1, NFR-PERF-1, NFR-PERF-2; the RT half of
  AT-ENGINE-\*.**

**Gate adjustment (`a7615e5`, owner decision):** the AT-PLIST-8 30k-candidate beam
gate was **2.0 s → 2.5 s**. Root cause found: not load — the owner's **Low Power Mode
on AC** caps CPU clocks on this M2. Measured 1235 ms with LPM off, 2040–2073 ms with
LPM on, identical across load averages 63 → 2. Owner keeps LPM on sometimes, so the
gate sits at 2.5 s (still under the 3 s budget).

**Gate adjustment (owner decision):** the AT-PLIST-8 gate was raised again
**2.5 s → 4.0 s** (`SequencerTests.testThirtyThousandCandidateBeamStaysInsideBudget`)
to keep it from failing in a clock-capped Low Power Mode state.

## Uncommitted in the working tree — the DJ regression suite (commit 5.14, scaffolded early)

**Nothing here is committed.** It is one coherent change: the design *and* the scaffold
for the DJ regression suite, written ahead of its place in the sequence so the hooks it
needs can land with the commits that build the surfaces rather than being retrofitted.
It is safe to commit as-is, or to leave sitting while 5.5/5.6 and the remaining 5.7–5.13 proceed.

Verified before writing: `xcodegen generate` has been run and the three new lanes are in
`project.pbxproj`; `xcodebuild build-for-testing -scheme TonearmUIRegression` compiles
**clean, zero warnings**; `verify-mix.py` was validated against synthesized audio — it
passes a real bass swap (37 dB out / 37 dB in, mids held) and **fails a fake one** where
the mids drop too, reporting "that is a cut, not a swap". The discriminating assertion is
real, not decorative.

| Path | What it is |
|---|---|
| `docs/plans/dj-regression-suite.md` | **new** — the coder brief: oracle rationale, fixture design, the five signature definitions, lane inventory, commit hooks, traps |
| `UIRegressionTests/DJPerformanceDriver.swift` | **new** — bar-aware gesture driver (`waitForBar`, `sweep`), the §53.11 identifier constants, `MIX_MINUTES` |
| `UIRegressionTests/DJMixRegressionUITests.swift` | **new** — `AT-MIX-1..8`, bodies `XCTSkip` per the §53.6 precedent |
| `UIRegressionTests/DJLiveMixRegressionUITests.swift` | **new** — `AT-MIX-9..10`, live Jamendo, skips without a `client_id` |
| `scripts/ui-regression/make-dj-fixture-media.py` | **new** — tone-identity fixtures; runs, writes 8 WAVs + a manifest |
| `scripts/ui-regression/verify-mix.py` | **new** — the host-side analyzer; pure stdlib, targeted windows around journal marks |
| `scripts/ui-regression/jamendo-mock/serve.py` | **new** — canned catalogue + fixture media over HTTP |
| `docker-compose.ui-regression.yml` | + `dj-fixture-media`, `jamendo-mock` services |
| `scripts/run-ui-regression.sh` | + `djmix`/`djlive` lanes, container artifact pull, analyzer invocation, artifact policy |
| `Makefile`, `.gitignore` | + `MIX_MINUTES`; ignore `build/ui-regression/` |
| `.test-credentials.example` | + `[jamendo]` — **key name only**, no value |
| spec, M5 plan, HANDOFF, this file | §53.7–53.12, §54.6, `AT-MIX-*`, decisions 26–30, commits 5.4a/5.14 |

**The recorded mix is kept on purpose.** `build/ui-regression/dj/` holds exactly one audio
file so a human can play it and judge whether the analyzer's thresholds are tuned right —
a failing signature over a mix that *sounds* wrong means the app is broken, while a failing
signature over a mix that sounds right means the *threshold* is wrong, and without the audio
those are indistinguishable. The directory is wiped at the **start** of every DJ run (so a
rerun never leaves you auditioning the previous mix), intermediates are deleted at the end,
and `KEEP_INTERMEDIATES=1` retains them for debugging.

**Correction worth carrying forward:** the "DJ files need no `xcodegen generate`" shortcut
holds **only** for `Sources/DJ/**`, which is an SPM target that globs at build time.
`TonearmUIRegressionTests` is an Xcode target and XcodeGen writes explicit file references
into `project.pbxproj`, so new `UIRegressionTests/*.swift` files are invisible to
`xcodebuild` until a regen runs. Verified against the existing lane files.

## Next

- **M5 commit 5.5 — the §35A echo + AT-TRANS-1..5 — complete (`559b23a`).** The one
  Beat FX M5 ships (decision 23): `BeatEcho` (pure control value + `BeatEchoLine` ring
  DSP — fixed-capacity, **crossfaded read-pointer on delay change**, feedback clamped
  below unity, disabled continues the tail then bypasses) placed **post-fader,
  pre-crossfader, per channel** (§35A.1 — the whole design); `setEcho*` RTCommands +
  façade; the delay retuned per callback from the master clock. Surfaces: the mixer
  column's Beat FX block live (A/B channel, five beat lengths, drag depth, `dj.fx.echo`),
  the iPad FX slot's ECHO pad live, and the compact **`EchoReleaseToCommitButton`** — an
  always-visible ECHO with a release-to-commit flyout (channel/beats/depth, pure frames +
  `releasedAction(at:)`, engine touched only on a commit release). Tests: 8 `BeatEchoTests`
  + 7 `TransitionTests` (**AT-TRANS-1..5** — audio half as scripted offline-render
  sequences with Goertzel band assertions, layout half asserting reachability on both
  surfaces) + 4 `WorkspaceModelTests`. Suite 1262 → **1289 green**; DJ-only, no regen.
  **FR-TRANS-3/4/5, §35A, §35B, AT-TRANS-1..5.**
- **M5 commit 5.6 — genre libraries — complete (`dee6a57`).** The practice-material
  connector (§18A, §41.1a, FR-LIB-9/10, **free tier**). `SourceKind.jamendoGenre`;
  `JamendoGenreProvider` + `JamendoAPI` + the curated `JamendoGenreTree` (Jamendo v3.0
  has **no `/genres` method** — verified live; the hierarchy is curated and filters via
  `tags=` + `order=popularity_total` + `fullcount=true` + `include=musicinfo`);
  registered in `RemoteConnectorCatalog`; a genre is an ordinary Source row whose
  identity is the genre path, flowing through the standard row factory so FR-LIB-8 /
  cache / analysis / decks need no special-casing. `client_id` is an app credential
  (`JamendoClientID` / `TONEARM_JAMENDO_CLIENT_ID`, Info.plist); an unconfigured build is
  the honest `.notConfigured` state (§18A.6). `GenrePickerModel`/`GenrePickerView`
  (mockup `ipad/15`): curated tree, multi-select, lazy fullcount counts, equally-weighted
  Skip, gating-nothing account checkbox, licence stated once. Two doors — first-run
  onboarding page + Add source. Tests: 16 `GenreLibraryTests` (**AT-GENRE-1..7** against
  recorded fixtures, no live network). Suite 1289 → **1305 green**; app builds;
  **`xcodegen generate` committed** (decision 25). **FR-LIB-9/10, §18A, §41.1a,
  AT-GENRE-\*, AT-FREE-\*.**
- **M5 commit 5.8 — stem voices live on decks — complete (`118320d`).** The §35.1 reader's
  second slot + the model's honest status (plan decisions 3–4, FR-ENG-3, §36.5): the pure
  `StemSet` (four `DeckSource`s, one shared grid); `DeckState`'s armed `StemSet` slot with
  per-voice smoothed gains + mute/solo; `armStemSet`/`setStemGain`/`setStemMute`/`setStemSolo`
  RTCommands + façade; **a deck with no stem set is byte-for-byte the current reader**, an armed
  set sums the four voices then runs the chain once; the master clock/sync/echo read the set's
  grid. `DeckStemStatus` (`unavailable/separating/prepared`), `StemControlState`, the
  `StemProviding` seam + `StemLoader` (cache → `StemSetBox`); load arms a prepared set
  (`.prepared`, faders live) or disarms to full mix (`.unavailable`, **inert** faders — §36.5's
  honest rule); the iPad STEMS module + compact drawer faders go live when prepared. Tests: 7
  `StemVoiceTests` (frame-exact summing, bit-identical fallback + sample-transparent
  arm/disarm, gain/mute/solo, armed-grid master clock) + 6 `WorkspaceModelTests` (honest state
  machine). Suite 1327 → **1340 green**; Swift 6 guard OK; app builds; no regen. **FR-ENG-3,
  §35.1, §36.5, AT-STEM-\* (engine rows).**
- **M5 commit 5.9 — gig crates + storage budget — complete (`6dc5f80`).** The §41.17 surface
  (mockup `ipad/14`), the §43.6 disk budget, and the §36.3 lane (plan decisions 2, 11;
  FR-PLIST-9, FR-ANL-9, FR-LIB-8, **AT-STEM-\***). `GigCrateRepository`: promotion from a
  playlist in one transaction, stamping each track's FR-LIB-8 `audioCached` flag at promotion
  time; `markPerformed` (the LRU clock); roll-up list/detail; `cratesByLRU`. The pure
  `StorageBudgetService`: per-device-class stem budgets (4/12 GB), the ~13 MB/track
  projection, `mixesEvictable = false` always, and `plan(...)` → the eviction **preview shown
  before any eviction** (LRU by `lastPerformedAt`, protected crates never candidates).
  `StemService`: the crate-scoped lane — budget → evict LRU crates to make room → serialize
  pending tracks; pauses under the FR-ANL-2 performing fence, abandons when the `.stems`
  governor lane is shed (mid-run flip leaves the rest `pending`), model absence stays
  `pending` (never a fake failure); `separateOnDemand` (§36.5) caches so the next load is
  instant. `GigCrateModel`/`GigCrateView`: stat cards, governor panel, track table with the
  FR-LIB-8 Local/Caching pill, the "One track can't go on a deck yet" notice, and the
  "Making room" eviction preview. Tests: 7 `GigCrateTests` + 11 `StorageBudgetTests` + 10
  `StemServiceTests` + 5 `GigCrateModelTests` — the lane evicting the LRU crate to make room
  (real cache rows removed, `evicted` marked), mid-run abandonment, the performing fence.
  Suite 1340 → **1373 green** (8 skipped); Swift 6 guard OK; app builds; no regen. **FR-PLIST-9,
  FR-ANL-9, FR-LIB-8, §41.17, §43.6, AT-STEM-\*.**
- **M5 commit 5.10 — the record tap + encoder + segmented M4A — complete (`1f07de9`).** The
  §37.2 recording path + the milestone's record toggle (decision 14, FR-ENG-7): `RecordTap`
  (RT-safe post-limiter master copy into a pre-allocated SPSC ring — idle unless recording,
  full ring **drops and counts** so a slow encoder never stalls the live performance) +
  `RecordingEncoder` (off-RT actor, AAC 256 kbps segmented M4A with periodic flush,
  `finalize()` → `RecordingOutput`). `recordTapEnabled` defaults false so the reader harness
  stays bit-exact. `PerformanceEngine.startRecording/stopRecording` under
  `DJDatabase.mixesDirectory` (user content, never a cache, §43.6). `WorkspaceModel`
  `isRecording` + `recordingElapsed` session state; the mixer-column record chip carries
  `dj.transport.record` (the regression-suite hook 5.10). Tests: 7 `RecordTapTests` (bit-exact
  tap match, idle bit-exact, dropped-drain absorption, playable segmented M4A round-trip,
  flush on budget, start/stop, honest no-tap) + 3 `WorkspaceModelTests`. Suite 1373 → **1383
  green**; DJ-only, no regen. **FR-ENG-7, §37.2.**
- **M5 commit 5.12 — Finish + Mixes + the review listen — complete (`4cbbf04`).** The §37.4
  timeline (decision 8, control-side: `WorkspaceModel` logs a deck's playing edge while recording;
  `finalize` gains `timeline:` + returns the finished `DJMix`, writing `mix_track_event` rows +
  `trackCount` in the journal's one transaction) + `MixRepository` (completed/corrupt listing,
  events, asset URL, update, delete, storage) + **the review listen** (FR-REC-6: `MixPlayback`
  seam + AVAudioPlayer, the streaming `MixWaveformBuilder` overview, seekable waveform with tappable
  transition markers) + `RecordingFinishView` (mockup `ipad/09`: title/notes, pills naming
  **M4A · AAC 256 kbps**, timeline table, attribution §18A.5, export with the optional cue-sheet,
  honest corrupt/absence, Delete) presented off `model.finishedMix` on all three surfaces + the
  free `MixesView` (mockup `ipad/10`, FR-REC-5) via the new `dj.mixes` route. Tests: 7 + 7 + 10 +
  3 + 3 + 2 new + `DJEntryTests`/`WorkspaceModelTests` updated. Suite 1397 → **1433 green** (8
  skipped); Swift 6 guard OK; app builds; smoke pass in the pre-commit hook; DJ-only, no regen.
  **FR-REC-1/4/5/6/7, §37.4, §41.11, §41.12, §18A.5, AT-REC-\*.**
- **Then 5.13** the transition coach →
  **5.14 the DJ regression suite**.
  **Exit:** AT-STEM-\*, AT-REC-\*, AT-WAVE-\*, AT-TRANS-1..5, AT-GENRE-\*,
  **AT-MIX-1..8** green, plus the owner's end-to-end recorded set as the user-owned
  shipping gate.
- **5.14 — the DJ regression suite** (`docs/plans/dj-regression-suite.md`, spec
  §53.7–53.12). The M5 exit narrative driven through the real UI and asserted
  against **the recording the app produces**, because `XCUITest` cannot hear and a
  lane that asserts "the deck row says Playing" is the D-10 false green exactly.
  Synthetic **tone-identity** fixtures (deck A 55/611/5300 Hz, deck B
  87/1290/8900 Hz) make band energy attributable to a specific deck, which is what
  turns "did the bass swap?" into a question with a crisp answer. `LANES=djmix`
  gates the milestone; `LANES=djlive` hits real Jamendo and informs it. **By hand,
  never in CI** (§53.2).
- **Post-M4 device pass** (user-owned ship gates, one pass per handoff §8 and the M4
  plan §2.11): **AT-THERM-1** (60-minute two-deck session, battery, 50% brightness,
  never `.critical`, §43.7), **AT-MEM-1** (the same session never crosses the §43.5
  footprint ceiling — the `MemoryCeilingMonitor` is shipped and unit-tested), the M3
  leftovers **AT-PLIST-2** (on-device timing) and **AT-PLIST-7** (listening), and the
  physical AT-SESS-\* route events. Then **ship 3.0 — the Pro launch**: AT-ENGINE-\*,
  AT-SESS-\*, AT-STORE-\*, AT-TWIN-\* are green; app builds; the purchase unlocks the
  decks with no relaunch (AT-STORE-2). **Ask before `git push`** — push triggers CI +
  TestFlight and 3.0 is the release gate.

## After M4

- **2.6 — Tier B sqlite-vec** (deferred): blocked on the user-owned §50.3
  real-device FR-SEM-3 measurement.
- **M1 exit-gate leftovers** (blocked, user-owned): paid products in App Store
  Connect; Plex claim token + cloud OAuth registrations into `.test-credentials`.
- **M5** — **in progress**, re-scoped (see Working on). The `dj_v4` migration adds the
  recording tables + `stem_cache`; `phrase`/`downbeat`/`waveform_pyramid`/`beat_blob`
  already exist in `dj_v2` and only need writing (plan §4). Then M6 hardware/Watch.
- **Deferred to M6, recorded not dropped:** MP3 export via a vendored encoder (§37.6),
  contingent on an LGPL review; additional Beat FX beyond the echo (§35A.4).

## Standing rules in play

Work on `main`, one commit per numbered task, no `Co-Authored-By` trailer (owner
preference). **Ask before `git push`** (push triggers CI + TestFlight). Every commit
runs the full local suite in the pre-commit hook (allow ~5 min). `xcodegen generate`
after project.yml changes (DJ-only file additions under `Sources/DJ/**` need no regen —
the app target excludes `DJ/**`; TonearmDJ is the SPM target — **but M5 commits 5.1 and
5.6 touch app-target / `Sources/Domain` / `Sources/Remote` files and DO need regen**).
**One new network host is authorised for M5** — the Jamendo API, owner-approved under
handoff §9, recorded in the plan (decision 20) and §18A.2; no others. Still **no new
dependencies**, no StoreKit outside `Sources/Pro/`, no `#if os(...)` around DJ core
modules. Swift 6 language mode + strict concurrency, warning-free.

**CI runs `swift test` only.** The UI regression suite — including the new **DJ
lanes** (`LANES=djmix|djlive`, spec §53.7–53.12) — is run **by hand** before a release
and after major changes. It must never be wired into CI, `make test-swift`, or a git
hook. The DJ lanes need Docker, a simulator with a real-time audio device, and up to
20 minutes, so the pull toward "just add it to the nightly" is stronger than it was
for the original lanes; the answer is unchanged. The separate target/scheme
(`TonearmUIRegressionTests` / `TonearmUIRegression`) keeps that structural, not
conventional. **No credential outside `.test-credentials`** — the Jamendo `client_id`
included — and **no third-party audio committed**, Creative Commons included (§54.6);
DJ fixtures are generated tones.

**Known flakes / environmental gates:**
- ~~`OnsetTests.testNoiseDoesNotProduceSpuriousPeaks`~~ — **fixed in `1290b31`**: the
  noise test is now seeded `SplitMix64` (which gained the `RandomNumberGenerator`
  conformance), so `peaks.count < 3` is deterministic (NFR-DET-3). It had blocked a
  commit attempt (3 vs 3) intermittently before the fix.
- `SequencerTests.testThirtyThousandCandidateBeamStaysInsideBudget` — gate raised
  2.5 s → 4.0 s (owner decision). Root cause was Low Power Mode capping
  CPU clocks (1235 ms off, ~2.05 s on), not load; measured stable across load
  averages 63 → 2. At the 4.0 s cap it passes in both states.
