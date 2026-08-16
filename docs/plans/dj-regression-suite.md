# The DJ Regression Suite — plan and coder brief

**Status:** **implemented in commit 5.14** — `LANES=djmix` runs end to end and all five §6 signatures
verify against the journal. The per-commit hooks in §9 landed with it rather than earlier; §14 records
what the suite's first run found, which is the case for its existence.
**Governs:** spec §53.7–§53.12, §54.6. **Milestone:** M5 (§48.6).
**Audience:** the agentic coder who implements it, and the owner who runs it.

---

## 1 · What this is, in one sentence

The M5 exit gate is written as a sentence the owner has to be able to perform —

> grab the latest most interesting genre tracks, construct an A-deck playlist and a B-deck
> playlist, start mixing right away, apply the five basic transitions of DJ Blakey, record a
> twenty-minute set, listen to it immediately afterwards, and share it with friends.

— and **this suite is that sentence executed by a machine.** It is not a new test family invented
for its own sake; it is §48.6 turned into something that either passes or does not.

Run by hand, before a release and after any major change. Never in CI, never in a hook.

---

## 2 · Why it must exist above the tests we already have

There are three layers, and each is blind to what the next one catches.

| Layer | Where | Proves | Blind to |
|---|---|---|---|
| 1 · Kernels & offline render | `swift test` (CI) | The **DSP is correct**. `AT-TRANS-1..5`'s audio half drives scripted command sequences into the offline `AudioGraph` and asserts the output buffer. | Whether any of it is reachable from a finger. |
| 2 · Layout assertions | `swift test` (CI) | The **controls exist**, are ≥ 44 pt and un-occluded on both surfaces. | Whether touching them does anything. |
| 3 · **This suite** | by hand | The **wiring**: a real gesture on a real control → view model → command ring → engine → recording → finalize → export → a file that decodes and contains the mix. | Nothing above it. It is the last layer. |

Layer 3 exists because of what M4 taught us. The M4 engine was correct, tested, and **completely
unreachable** — no file outside `Sources/DJ/` referenced any performance surface. Every layer-1 and
layer-2 test was green while the feature did not exist in the shipped binary. That became spec
invariant §49.3a ("a feature is not done until it is reachable, and until real data flows through
it"). **This suite is that invariant made into a standing guard** rather than a lesson we remember
for one milestone.

State that motivation in the suite's own doc comment. A future reader who does not know why layer 3
exists will eventually propose deleting it as redundant with layer 1.

---

## 3 · The blocking prerequisite: there is no real-time pump

**Verify this before writing anything else; if it has already been fixed, note that and move on.**

As of commit 5.2:

- `AudioGraph.init` calls `engine.enableManualRenderingMode(.offline, …)` **unconditionally**
  (`Sources/DJ/Engine/AudioGraph.swift:199`). There is no device-output topology and no branch that
  would produce one.
- The only thing that ever produces samples is `AudioGraph.render(_:)`, a pull driven by the
  caller (`:325`).
- The only callers of `render()` are `PerformanceEngine.render` / `renderMono`
  (`Sources/DJ/Engine/PerformanceEngine.swift:282,288`), and **the only callers of those are unit
  tests.**
- The app does construct a real engine — `DJEntryModel.swift:58` does `try? PerformanceEngine()` —
  so commands from the UI reach the ring and are applied.

The consequence: **in the shipped app today, pressing PLAY advances no clock and emits no audio.**
The commands are accepted and dispatched into a graph that nobody pulls.

This is not a defect in anything already committed — 5.1's job was reachability of the *surface*,
and every M4 acceptance test is honest about running offline. But it is a hidden prerequisite that
sits underneath the entire M5 exit gate. You cannot record a mix that was never rendered, and no
amount of UI automation will make a silent engine audible.

### 3.1 Commit 5.4a — the real-time pump

Inserted before 5.5 (the first commit that needs to *hear* something), lettered rather than
renumbered so the recorded 5.5–5.13 sequence in Appendix M.6 and the audit table stay stable.

- `AudioGraph.Configuration` gains a `rendering` mode: `.offline` (today's behaviour, unchanged,
  still the default for tests) and `.realtime`.
- In `.realtime`, the graph does **not** enable manual rendering. The same `AVAudioSourceNode`s and
  the same render closures connect through to `mainMixerNode → outputNode`, and the clock is
  advanced inside the render callback rather than by `render(_:)`.
- **The render closures are not duplicated.** The whole value of the existing design is that one
  closure body is what the offline tests exercise. If the realtime path grows its own copy, layer 1
  stops proving anything about what ships. One body, two drivers.
- `AudioSessionCoordinator` is entered before the engine starts, in the §34A.2 normative order.
- The `.offline` path keeps every existing test green, unchanged. That is the acceptance criterion:
  **suite stays green, plus the app makes sound.**

Do not let 5.4a expand. It is a topology switch, not a rewrite.

---

## 4 · The design problem, and the answer

**XCUITest cannot hear.** There is no supported way for a UI test to observe the simulator's audio
output. So what is the oracle?

Three candidates, in ascending order of honesty:

1. **UI state** — "the deck row says Playing". This is exactly the D-10 failure mode the existing
   suite was built to catch: a library that adds cleanly and plays nothing. A lane asserting only
   this would have passed for the entire life of that defect. Never sufficient alone.
2. **Engine telemetry surfaced through accessibility** — the playhead advances, the bar counter
   increments. Better, and useful for *timing gestures*. But it is the app's own claim about
   itself; a mixer bug that drops a channel entirely would not move it.
3. **The recorded mix file.** ← **this one.**

### 4.1 The recorded artifact is the oracle

The app already has to produce a recording of the master bus, finalize it to M4A, and export it —
that is commits 5.10–5.12 and it is the thing the owner ships to friends. So:

> **The suite drives the real UI in real time; the app records its own master output; the runner
> pulls the resulting file off the simulator; and a host-side analyzer proves the five transitions
> are acoustically present in it.**

This is the right oracle for four reasons:

- It is **independent of the app's opinion of itself**. The file is decoded by `ffprobe`/`soundfile`
  on the host, not by Platterhead.
- It is **the actual deliverable**. Verifying it verifies the milestone rather than a proxy for it.
- It **cannot be faked by a UI that looks right**. Audio either has the low band or it does not.
- It **catches the whole chain at once** — gesture, ring, engine, mixer, tap, encoder, finalize,
  export. Any break anywhere shows up as a wrong signature.

Corroborate with (2), never rely on (1) alone. That is §53.5 applied to mixing.

---

## 5 · The fixture design that makes assertions provable

Real music makes every one of these assertions mush. A Jamendo techno track has broadband low end
on both decks; "did the bass swap?" has no crisp answer. So the deterministic lane uses
**synthesized tracks with per-deck tone identity.**

`scripts/ui-regression/make-dj-fixture-media.py` writes a small set of WAVs. Each track is built
from three sine tones, one per EQ band — and **the two decks use different frequencies within the
same band:**

| Band (EQ crossover) | Deck-A tone set | Deck-B tone set |
|---|---|---|
| Low (< 200 Hz) | **55 Hz** | **87 Hz** |
| Mid (200 Hz – 2 kHz) | **611 Hz** | **1290 Hz** |
| High (> 2 kHz) | **5300 Hz** | **8900 Hz** |

The frequencies are deliberately **not** in simple integer ratios, so no tone is a harmonic of
another and intermodulation cannot be mistaken for the tone it sits near. They sit unambiguously
inside the same 200 Hz / 2 kHz crossovers the mixer's three-band EQ uses (§26A.2), so "the LOW knob
kills the low band" and "the 55 Hz tone disappeared" are the same statement.

**This is the trick that makes the suite work:** band energy is not merely measurable, it is
*attributable to a specific deck*. Bass Swap stops being "the low band changed somehow" and becomes
**energy at 55 Hz falls while energy at 87 Hz rises, and both mid tones are untouched** — which is
precisely, and only, what a bass swap is.

Other fixture properties:

- **Every track is exactly 122.000 BPM**, so the transition lanes need no tempo change and no
  time-stretch is in the signal path to smear the tones. A separate pair at **124.000 BPM** exists
  for the sync lane only.
- Each tone is **amplitude-modulated on the beat** (short percussive envelope) so tempo and beat
  positions are genuinely detectable by the analyzer and by the app's own analysis, and so beat
  alignment is measurable for the Blend lane.
- **16-bar phrase structure** — tones enter and drop at phrase boundaries so the segmenter produces
  a real phrase ribbon and "swap on the phrase boundary" has a boundary to land on.
- Peak level **−12 dBFS** per track, leaving headroom so that a limiter engagement in the Blend
  lane is meaningful rather than inevitable.
- At least **6 tracks** (alternating tone sets) so the 20-minute soak has material without looping
  one file.

Generated, never committed — same rule as §54.1, for the same reason. No binary in the repo, and
unmistakable if it ever plays by accident.

---

## 6 · The transition signatures — the acoustic oracle

This table is the heart of the suite. Each row is what must be **true of the recorded file** for
that transition to have actually happened. `E(f)` is energy in a narrow band around tone `f`,
measured over short windows (suggested 4096-sample Hann, 50% overlap, via Goertzel or FFT bin).

| # | Transition | Signature required in the recording |
|---|---|---|
| 1 | **Bass Swap** | `E(55)` falls ≥ 24 dB **and** `E(87)` rises ≥ 24 dB across the journal mark, measured on the settled state either side of it (§6.1). **`E(611)` and `E(1290)` each stay within ±3 dB across the boundary.** The mids persisting is what distinguishes a bass swap from a cut — assert it, or lane 1 and lane 4 pass on the same evidence. |
| 2 | **Filter Transition** | Over the sweep window, the outgoing channel's spectral centroid rises **monotonically** (≥ 3 of 4 successive windows increasing). `E(55)` falls ≥ 18 dB while `E(5300)` stays within ±6 dB — a high-pass, not a fade. On release to centre, `E(55)` returns to within ±3 dB of its pre-sweep value: **centre is bypass** (§35.3). |
| 3 | **Echo Out** | After the channel fader reaches zero, the master **still contains** deck-A tone identities. The tail's envelope autocorrelation peaks at the beat-synced delay interval (`60/122 × division`) within ±5%, and successive peak amplitudes **decrease monotonically** to below −60 dBFS. This is the one lane that proves new DSP, and the one that proves it is **post-fader** — a pre-fader echo dies with the fader and produces no tail at all (§35A). |
| 4 | **Fader Cut** | RMS attributable to the outgoing deck falls ≥ 30 dB **inside one beat period**. No zipper: no broadband impulse at the cut — spectral flatness in the transition window stays below threshold, i.e. the step did not create a click across all bins. |
| 5 | **Blend / Mix** | Both decks' tone identities are present simultaneously for ≥ 8 bars. Master true peak **never exceeds the limiter ceiling** — read from the journal's engine-config block (§7), never hardcoded in the analyzer. Beat alignment holds: the master's beat-rate autocorrelation stays single-peaked at the 122 BPM interval across the blend — phase-locked, not flamming. |

**Reuse layer 1's thresholds.** Where `AT-TRANS-*` already defines a constant for "true kill" or
"decays to silence", the analyzer imports the same number rather than inventing a second set that
can drift out of agreement with the DSP tests.

### 6.1 Ratio-based and bar-tolerant, never sample-exact

Sample-exactness is **layer 1's** job and layer 1 already does it against a deterministic offline
render. Layer 3 runs in real time on a simulator whose audio can underrun, and behind gestures
whose timing is approximate. So every assertion here is:

- **relative, not absolute** — dB *changes* and *ratios* between tones, never absolute levels;
- **bar-tolerant** — whole bars around the journal mark, never a sample offset;
- **allowed a dropout budget** — a small number of underrun gaps does not fail a lane. Measure and
  report them; fail only if they exceed the budget, and say so as a simulator condition rather than
  a product defect.

An analyzer that demands sample precision from a simulator will be red for reasons nobody can fix,
and a suite that is red for unfixable reasons stops being read (§53.4).

**Windows go on the settled state, not on the movement — and the lane has to leave room for
them.** A journal mark is where the app *recognised* the gesture, which for the two multi-step
transitions is where it **began**: a bass swap is marked at the outgoing low being killed, with the
incoming deck's knob still to reach; a filter sweep is marked as the knob leaves the bypass band,
with the sweep still to travel. A window one bar past such a mark measures the transition
mid-flight, and reports a real, correct transition as a half-failure — a measurement bug, not a
threshold that wants loosening. Each check therefore names the bar offsets it measures over
(settled before, settled once the gesture has landed; a mark that fires at a movement's completion,
like the return to bypass, needs only a guard bar), and **the lane schedules every gesture relative
to the bar the previous one finished on**. Against an absolute bar grid the spacing silently
collapses: each gesture is paid for out of the gap meant to follow it, a wait for a bar already
passed returns instantly, and the transitions land inside each other's windows (§14).

---

## 7 · Cross-checking against the journal

The analyzer must not be free to hunt the file for a bass swap and declare victory wherever it
finds one. Commit 5.11 delivers `MixTrackEvent` — the recorded journal of what happened when.

Under `-uiRegression`, the app exports **`mix-journal.json` beside the M4A**, carrying each event's
kind and sample offset. The analyzer then:

1. reads the journal to learn **where each transition claims to be**;
2. verifies the acoustic signature **is present there**;
3. verifies **no unexplained** transition-scale event exists elsewhere in the file.

This turns two independent artifacts into a cross-check. The journal alone proves only that the app
believes it did something; the audio alone proves only that something happened. Together they prove
the app did what it says it did, where it says it did.

**The journal also carries the engine configuration** — limiter ceiling, master BPM, echo division,
sample rate — so the recording is **self-describing**. This is how §6's "reuse layer 1's thresholds"
is actually mechanised: the analyzer is host-side Python and cannot import `Limiter.ceiling`, so the
app writes the value it really used and the analyzer reads it. Without this the analyzer hardcodes
`0.95`, someone later retunes the limiter, and the Blend lane silently asserts against a number the
engine stopped using.

---

## 8 · The two lanes

### 8.1 `LANES=djmix` — the deterministic journey (the one that gates M5)

Fixture media, mock catalogue, tight assertions. This lane is the gate because it is the one that
can be **trusted to mean the same thing every run**.

A `jamendo-mock` service in the existing compose file serves canned catalogue JSON plus the fixture
WAVs, so the **real browse UI path** — genre picker → genre library → per-deck playlists — is
exercised without depending on a third party being up. The app points at it via a
`-jamendoBaseURL` launch argument, honoured **only** under `-uiRegression`.

Lanes, each mapping 1:1 to an acceptance ID:

| ID | Lane |
|---|---|
| `AT-MIX-1` | Genre picker → genre library → browse by "most interesting" → build **two different** playlists |
| `AT-MIX-2` | Per-deck sources: deck A and deck B draw from **different** playlists simultaneously (FR-ENG-13); both decks load and both playheads advance |
| `AT-MIX-3` | **Bass Swap** |
| `AT-MIX-4` | **Filter Transition** |
| `AT-MIX-5` | **Echo Out** |
| `AT-MIX-6` | **Fader Cut** |
| `AT-MIX-7` | **Blend / Mix** |
| `AT-MIX-8` | Record → finalize → **review listen** → export; the file decodes, its duration matches the journal, and every signature above is verified in one continuous recording |

`AT-MIX-3..7` are performed **inside one continuous recording**, not as seven separate sessions.
That is what "a live mix" means, and it is the only way a transition's tail can be observed running
into the next one.

### 8.2 `LANES=djlive` — real Jamendo, looser assertions

The same journey against the live API. Assertions are deliberately weaker because the material is
uncontrolled: tracks browse, load, and play; the recording reaches the expected duration; the export
decodes; the journal is well-formed. **No tone-identity assertions** — real music has no tone
identities.

Its job is to catch what the mock cannot: a changed endpoint shape, a paging bug, a licence field
that stopped arriving, an audio format the decoder rejects. API unreachable or `client_id` absent →
**skip with the remedy stated**, per §53.4.

### 8.2a What a run costs, and why

A `djmix` run is about fifteen minutes of wall clock at the default `MIX_MINUTES=6`: the Release
build, then **fixture synthesis** (the runner tears its compose volumes down on exit, so the
fourteen WAVs are regenerated from scratch each time — a deliberate trade for a clean slate every
run with no new dependency in the repo), then the mix itself in something close to real time. Do
not cache the media, because a stale fixture is a suite that measures last week's assumptions.

The mix runs in *close to* real time and not exactly: the app has to keep a 2.67 ms render deadline
to hold 1×, which is why the runner builds Release (§14). Measured at Release, ten 30-second
segments land in ~300 seconds of wall clock — 1.00×. If a run takes markedly longer than
`MIX_MINUTES` for the mix portion, the render rate printed by a `holdMix` failure is the number to
look at — the graph, not the script, is the slow part.

**The host has to stay awake for the whole run.** The simulator's audio is a proxy to the Mac's
Core Audio, so when the machine sleeps the app's render callback stops being pulled and the mix
dies where it stands (§14). The runner takes a `caffeinate -dims` assertion for the length of the
build, which covers display and idle sleep but *not* a clamshell close on battery. On a laptop:
leave the lid open, or run it on power with an external display attached.

### 8.3 Duration is a parameter

`MIX_MINUTES`, default **6** — long enough to perform all five transitions with phrases between
them, short enough to run often. `MIX_MINUTES=20` is the pre-release soak that exercises the real
exit-gate duration, memory ceiling, and thermal behaviour.

Twenty real-time simulator minutes as the *default* is a flake generator and would get the suite
switched off. Make the fast path the default and the honest path explicit.

---

## 9 · What must land in earlier commits (hooks — do these on the way past)

The suite is unwritable unless these exist. Each is small; each belongs to a commit already in the
plan. **Add them to that commit's definition of done now**, not when 5.14 discovers they are
missing.

| Commit | Hook |
|---|---|
| **5.4a** *(new)* | The real-time pump (§3.1). Without it there is nothing to record. |
| **5.4** | **Accessibility identifiers on every performance control**, to a stated convention: `dj.deck.<a\|b>.<play\|cue\|filter\|fader>`, `dj.deck.<a\|b>.eq.<low\|mid\|high>`, `dj.mixer.crossfader`, `dj.fx.echo`. Plus `dj.master.bar` exposing `bar:beat` — the suite polls it to schedule gestures on phrase boundaries, which is how a scripted mix stays musical. Identifiers are part of the control's contract, not test scaffolding. |
| **5.6** | `-jamendoBaseURL` launch-argument override, honoured **only** under `-uiRegression`, so the mock can stand in for the live API. |
| **5.10** | The record tap must be reachable from the UI under automation — a `dj.transport.record` identifier and no confirmation the suite cannot dismiss. |
| **5.11** | `mix-journal.json` exported beside the M4A under `-uiRegression` (§7), **carrying the engine configuration in force** (limiter ceiling, master BPM, echo division, sample rate) so the recording is self-describing. |
| **5.12** | **The share sheet is unautomatable.** Under `-uiRegression` the share action writes the export to a known container path (`Documents/uiRegression/export/`) and publishes it on `dj.export.path`. The runner pulls it with `xcrun simctl get_app_container <udid> <bundle-id> data`. Do not attempt to drive `UIActivityViewController`. |

---

## 10 · Commit 5.14 — the suite itself

### 10.1 File manifest

```
UIRegressionTests/DJPerformanceDriver.swift      gesture driver: bar-aware waits, knob/fader drags,
                                                 the shared launch configuration
UIRegressionTests/DJMixRegressionUITests.swift   AT-MIX-1 … AT-MIX-8   (djmix)
UIRegressionTests/DJLiveMixRegressionUITests.swift  AT-MIX-9 … AT-MIX-10 (djlive)
scripts/ui-regression/make-dj-fixture-media.py   §5 tone-identity fixtures
scripts/ui-regression/verify-mix.py              the analyzer — §6 signatures + §7 journal check
scripts/ui-regression/jamendo-mock/serve.py      canned catalogue + fixture media over HTTP
docker-compose.ui-regression.yml                 + `dj-fixture-media`, `jamendo-mock` services
scripts/run-ui-regression.sh                     + `djmix` / `djlive` lanes, artifact pull, analyzer
Makefile                                         + `MIX_MINUTES`, DJ lane usage
.gitignore                                       + `build/ui-regression/`
.test-credentials.example                        + `[jamendo]` section, key names only
```

**This commit needs `xcodegen generate`.** The "DJ files need no regen" shortcut holds only for
`Sources/DJ/**` (an SPM target that globs at build time). `TonearmUIRegressionTests` is an Xcode
target, and XcodeGen writes explicit file references into `project.pbxproj` at generation time — the
existing lane files each appear there individually. Without a regen the new lanes are invisible to
`xcodebuild`.

### 10.1a The recorded mix is kept, and a human is meant to listen to it

Every §53.9 threshold is a judgement call — "24 dB is a kill", "±3 dB is unchanged". Those numbers
have to be tunable against reality, which means the artifact they were measured from cannot be
thrown away.

So the runner keeps **exactly one audio file**, at `build/ui-regression/dj/dj-mix.<ext>`:

- the directory is **wiped at the start of every DJ run**, so a rerun can never leave you
  auditioning the previous run's mix and drawing conclusions from it;
- every intermediate (journal, decoded WAV) is **deleted at the end** of a normal run;
- `KEEP_INTERMEDIATES=1` retains them for debugging;
- the path is printed at the end of the run, and the directory is gitignored — it is generated
  audio and never belongs in the repo.

A failing signature and a mix that *sounds* wrong mean the app is broken. A failing signature and a
mix that sounds right means the threshold is wrong. Without the file you cannot tell those apart,
and you will eventually "fix" the wrong one.

### 10.2 The analyzer runs on the host, not in the test bundle

`verify-mix.py`, invoked by the runner after the XCUITest phase. Python for the same reason
`make-fixture-media.py` is Python — numeric work with no dependency added to the app, and it can be
run by hand against a recording the owner made on a real device. Any Swift that does end up in the
suite is Swift 6 strict-concurrency like everything else.

The runner: starts services → runs the lanes → `simctl get_app_container` to pull the export and
journal → runs the analyzer → prints a per-transition verdict table.

### 10.3 Staged the way §53.6 staged the original suite

Scaffold **all** lanes in 5.14 as named tests with their acceptance IDs and `XCTSkip("TODO(AT-MIX-n)")`
bodies. Lanes fill in as their dependencies land, and **"the lane is green" is what closes the
acceptance ID.** This is the existing precedent and it works: it makes the remaining work visible
in the test output instead of in a document.

If 5.14 lands after 5.5–5.12, fill the bodies in the same commit. If the owner wants the scaffold
earlier for visibility, split it: scaffold now, bodies at the end.

---

## 11 · The rules that do not bend

- **Never in CI, never in a hook, never in `make test-swift`.** Same target
  (`TonearmUIRegressionTests`), same scheme (`TonearmUIRegression`) — the separation that makes
  "never in CI" structural rather than conventional already exists; these lanes inherit it. It now
  additionally needs a real-time audio device and up to 20 minutes. Restating it because a suite
  this thorough is exactly the one somebody will want to "just add to the nightly".
- **Skip-versus-fail (§53.4).** Docker down, Jamendo unreachable, no `client_id`, no simulator
  audio device → **skip with the remedy printed**. Only an assertion about Platterhead's own
  behaviour may fail a run.
- **No credentials anywhere but `.test-credentials`.** The Jamendo `client_id` goes in a new
  `[jamendo]` section; `.test-credentials.example` carries the key name only. Not in a test, not in
  the compose file, not in the mock, not in this document.
- **No third-party audio in the repo** — including CC-licensed Jamendo tracks. Fixtures are
  generated; the live lane streams and keeps nothing.
- **Swift 6 strict concurrency**, warning-free, for any Swift added.
- **One commit per numbered task on `main`; ask before pushing.**

---

## 12 · Non-goals, and the traps to avoid

- **Not a replacement for layer 1.** If a transition's DSP is wrong, `AT-TRANS-*` should catch it
  first, deterministically, in CI. This suite catches wiring. Do not migrate DSP assertions up here
  where they will be slower and flakier.
- **Not a snapshot/visual test.** No pixel comparison anywhere. Waveform *correctness* is layer 1
  (`AT-WAVE-*`); waveform *presence* is a layer-2 layout assertion.
- **Do not assert on absolute levels or sample offsets.** §6.1. This is the single most likely way
  for the suite to become flaky and get abandoned.
- **Do not test the share sheet.** §9, 5.12 hook.
- **Do not let the live lane gate the milestone.** It depends on a third party; it informs, the
  `djmix` lane gates.
- **Do not delete a lane to make a run green.** Same failure mode as deleting a geometry test to
  make a relayout pass (plan decision 19).

---

## 13 · Definition of done

`make test-ui-regression LANES=djmix` runs end to end on a clean checkout with Docker up, and:

1. all of `AT-MIX-1..8` are green, none skipped;
2. the analyzer prints a verdict table with all five transition signatures **verified against the
   journal**;
3. the export decodes on the host and its duration matches the journal within a bar;
4. `MIX_MINUTES=20` completes without exceeding the memory ceiling (§43) or dropping the recording;
5. `LANES=djlive` is green or skips with a stated reason;
6. `make test-swift` is unaffected and CI still runs `swift test` only.

**M5 is not complete until (1)–(4) hold.** That is the point of the suite: it is the only artifact
that can tell the owner the milestone sentence is true.

**Where it stands (2026-08-15, commit 5.14).** All six hold. (1)–(3): four lanes green in 531.8 s
over a 363.6 s recording, all five signatures verified, and the length cross-check is now a real
assertion — the journal carries a `recording` block (frames, duration, dropped frames, format) and
the analyzer holds the decoded file against it, with §6.1's dropout budget reported from the §37.2
tap's own counter. (4): the `MIX_MINUTES=20` soak is green — 1205.0 s recorded with the recording
never dropping, all five signatures verified on the 20-minute file, peak resident footprint ~508 MB
against the 2.0 GB ceiling the simulator's RAM selects (and the 1.0 GB strictest device class); the
on-device AT-MEM-1/AT-THERM-1 numbers remain the user-owned device pass. (5): `LANES=djlive` skips
both lanes with "missing PH_TEST_JAMENDO_CLIENT_ID" and exits 0. (6): `swift test` is 1447 green,
8 skipped, unchanged.

---

## 14 · What the first run found

The case for a third layer is not an argument; it is this list. Every defect below was live on
`main` with **1447 logic tests green**, and none of them was visible to any of those tests.

| # | Defect | Why layers 1–2 could not see it |
|---|---|---|
| 1 | `EchoReleaseToCommitButton` is a bare `GeometryReader` — greedy — under `minHeight: 44`, a floor rather than a ceiling. It grew to fill the compact surface, taking the bottom bar and its opaque background with it, painting over the deck column and the crate sheet. | Every control stayed in the accessibility tree at its correct frame, so the layout assertions passed. The surface was, to a finger, a dead slab. |
| 2 | The app's dock (mini player + tabs) is a root overlay and sat on top of the crossfader, REC and Crate — §42.7a's never-occluded controls. An overlay takes the touch. | Layer 2 asserts geometry *within* the performance surface; the dock is not part of it. |
| 3 | `UI_TESTING_ENABLE_PRO` seeded the older `ProEntitlement` defaults flag, which no Pro capability reads. Every DJ surface was gated, dimmed and `allowsHitTesting(false)` under automation. | Nothing in CI launches the app. |
| 4 | The shipped app ran with **no master limiter** — the assembly passed no ceiling, so a hot two-deck blend clipped into both the output and the recording. | The limiter's own tests construct their graph explicitly; nothing asserted what the *app* builds. |
| 5 | The sweep filter was inverted on its high-pass side: one curve served both sides, so a knob just off centre jumped to a 12 kHz high-pass and sweeping further *restored* content. | Layer 1 asserted the endpoint it had been written against, and that endpoint was the buggy one. |
| 6 | Opening Recorded Mixes terminated the app — a `NavigationStack` nested inside the DJ route's own stack. | The mixes model and repository are fully tested; the crash is in the composition. |

Two more were in the suite's own plumbing, and are worth recording because they are the failure mode
§53.4 warns about — a lane that passes while asserting nothing:

- **A UI test does not inherit the runner's environment.** `xcodebuild` forwards only variables
  prefixed `TEST_RUNNER_`. Every `PH_TEST_*` key was absent inside the test process, and
  `RegressionEnv.require` turns an absent key into a skip — so the lanes were green by skipping.
- **The fixtures were not distinct.** Each tone role rendered the same bytes, and both genres served
  the same files, so the library's content-hash dedup collapsed twelve tracks into two and the second
  crate mirrored the first.
- **The lanes ran a Debug build, which cannot keep the real-time deadline.** 128 frames at 48 kHz is
  a 2.67 ms render budget; unoptimised Swift DSP overran it and the graph rendered as fast as the CPU
  allowed — a *third* of real time, stable to two decimal places across four runs. Nothing sounded
  wrong in the artifact (everything downstream of the graph is frame-domain, so the journal offsets
  and the tone measurements are identical at any render rate) but a "six-minute mix" took eighteen
  minutes of wall clock. The runner now builds `-configuration Release`, which is what a pre-release
  gate should exercise anyway.
- **`holdMix` measured a recording-time target against a wall-time deadline** — correct only if the
  render rate is exactly 1×. When it was not, the hold ended early and the assertion blamed decks
  that had never run dry, which sent three runs chasing fixture length and playback state. The hold
  now runs on recording time with the wall clock as a cap only, and a shortfall prints the observed
  render rate so the failure describes itself.
- **A stale export read as a pass.** The simulator container outlives the run, so when the recording
  lane failed before finalize, the analyzer was handed the *previous* run's mix and printed a verdict
  table of PASSes about audio nobody had just recorded. The runner now takes only an export newer
  than the moment the lanes started, and a missing one is a failure rather than a silent fallback.
  This is the single worst thing a suite can do, and it was one `find` away.
- **The host went to sleep in the middle of a run, and the suite blamed the decks.** A laptop lid
  closed at minute five of a six-minute mix. The Mac slept, `coreaudiod` called
  `HALS_IOEngine2::StopIO`, and because the simulator's audio is a *proxy* to the host's Core Audio
  the app's transport ended with it — "ending the transport, stopping the io thread", in the app's
  own log. AVAudioEngine's render callback was never pulled again, so the master clock stopped at
  bar 171, the record tap starved, and the recording froze at 5:07 with ten complete 30-second
  segments and an eleventh left unclosed. The app went on displaying `Stop · 5:07` for the next
  fourteen minutes. `holdMix` read the frozen recording clock as "a deck ran out of material",
  rotated eighteen times trying to fix it, and finally died on an unrelated tap into a crate sheet
  it had been hammering mid-animation — nineteen minutes to report a wrong cause. Three changes:
  the runner wraps `xcodebuild` in `caffeinate -dims`; `holdMix` watches the **master bar** as well
  as the recording clock and fails in twenty seconds with the frozen bar named, because a clock that
  is not advancing is a graph that is not being rendered and no gesture can restart it; and the
  transitions lane now proves the recording actually started instead of assuming the tap took.
  The one genuinely good piece of news in that run: ten 30-second segments in ~300 seconds of wall
  clock. **Release renders at 1.00×**, which closes the render-rate question above.

  It also exposed a real product gap, deliberately **not** fixed in 5.14: the app has no
  `AVAudioEngineConfigurationChange` observer and never checks `engine.isRunning`, so a stopped
  engine — on iOS a route change or a media-services reset, not a sleeping Mac — leaves a recording
  that is dead but still displays a running timer. That is an NFR-REL-2 concern and wants its own
  commit with its own tests, not a rider on the suite that found it.
- **The fader-cut check measured a band that cannot be attributed, and passed for months by
  luck.** It summed the outgoing deck's low, mid and high. But the two decks' low tones sit 32 Hz
  apart (55 and 87), which an 85 ms window cannot separate — so once the cut deck is 40 dB down,
  its "low band" is really the *surviving* deck's low bleeding into the bin. Whether the check
  passed therefore depended on how loud the other deck happened to be at that instant. On the run
  that exposed it the outgoing deck's mid fell 44 dB and its high 52 dB, a textbook cut, while
  the bleed capped the measured sum at 19.9 dB and failed the lane. `check_echo_out` had already
  hit this and documented it ("the two decks' lows sit 32 Hz apart, closer than this window can
  separate at tail levels") and measured the mid alone; the fader cut simply had not learned the
  lesson. It now measures mid and high. The zipper half had the same shape of error — flatness
  compared only against the material *before* the cut rises on every cut, because the outgoing
  tones leave the probe set; a real transient stands out from what follows it too, so it is now
  compared against both neighbours.
- **The runner could report a green gate having verified nothing — twice over.** `simctl
  get_app_container` refuses on a shut-down device, and `xcodebuild` leaves the simulator shut
  down whenever it booted it itself (i.e. whenever Simulator.app was not already open). The
  export could then not be pulled, and the run printed a warning and **exited 0**. A missing
  `mix-journal.json` did the same. Both are the stale-export failure mode in a different hat:
  the lanes only *perform* the mix, so a run without the analyzer's verdict has asserted
  nothing at all. The runner now resolves the named device and boots it, and treats an
  unretrievable export, an absent journal or a missing fixture manifest as a **failure**. The
  matching care is not to fire that rule when every lane *skipped* — `djlive` without a
  `client_id` records nothing, legitimately (§53.4) — so it distinguishes "ran" from "skipped"
  from the lanes' own output before demanding evidence.
- **The script's musical spacing was scheduled against an absolute bar grid, and collapsed.** Run
  six performed all five transitions and recorded them correctly — the mix was traced band by band
  on the host and every one of them is physically there — but the analyzer could only verify two.
  The cause was in neither the DSP nor the thresholds: each gesture takes bars to perform (a bank
  chip, a focus swap, a verified knob drag), an absolute `waitForBar(N)` pays for that out of the
  gap meant to follow it, and once the clock is past `N` the wait returns instantly. Sixteen
  intended seconds between two transitions came out as six, so the dense early transitions landed
  inside each other's measurement windows while the well-separated late ones passed. Two changes,
  and **no threshold was touched**: gaps are now `waitBars(n)` from wherever the last gesture
  finished, and each analyzer check measures the **settled** state of a movement rather than its
  middle (§6.1). The lesson generalises past this suite: when a real behaviour measures as a
  half-failure, look at where the window is before looking at what the number is.
- **`ensurePlaying` blind-tapped a toggle and then measured the wrong thing.** PLAY/PAUSE is one
  button, so tapping a deck that was already playing *paused* it — and the check that followed
  watched the **master** clock, which the other deck kept advancing, so the pause went unnoticed for
  the rest of the run. The deck's own transport titles itself with the action it offers
  (`telemetryDeck.playing ? "PAUSE" : "PLAY"`), which is the per-deck signal the driver should have
  been reading all along: tap only when it says PLAY, then confirm it flipped.
