# DJ Phase 3 — Auto-playlists: the sequencer, arcs, brief parsing, and the generated-playlist UI (Milestone M3)

Plan for milestone **M3** of the Platterhead iOS DJ build. Implementation is driven by this file
one commit at a time, on `main`, per handoff §8 and the working agreement in
`docs/plans/tonearm-mvp-ios/HANDOFF.md`.

**Spec:** `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`. Read §48.4 (goal/exit),
§4.3a (FR-PLIST-1..10), Appendix M.4 (manifest), and the sections each commit names (§28A in
full, §14.3, §38.2, §41.6–41.7, §42.4). **Appendix M.4's commit order is authoritative; §49.2's
implementation order (pure kernels → façade/actor → view model → view) is binding.**

## 1 · Milestone goal and exit (spec §48.4)

The free tier's hero feature: turning a sentence and a shape into an ordered sequence of tracks
from the user's own library. A deterministic brief extractor (no LLM — §28A.6) plus the existing
CLAP text encoder turn prose into a semantic anchor and editable chips; five closed-form energy
arcs (or a drawn one) give the sequence its shape; a pure beam-search sequencer
(§28A.3) optimises transition cost (BPM continuity, Camelot, timbre via the pooled CLAP vector,
energy step), arc adherence, duration, and artist/album spacing; a `PlaylistGenerator` actor
persists the brief, result, per-item scoring and per-brief rejections; and the generated-playlist
UI (mockups `ipad/05a`, `ipad/05b`, `iphone/03`) renders the sequence against the arc with
per-transition badges and lock / reject / replace / extend.

**Exit (§48.4):** FR-PLIST-2 (±5% duration) and FR-PLIST-8 (≤ 3 s) met; a blind listening check
where the generated sequence beats shuffle on the same track set. AT-PLIST-1..7 (§28A.7).
`make test-swift` green; app builds; **2.1 free release**.

## 2 · Resolved spec-vs-repo decisions (recorded up front)

1. **No `dj_v4` migration — the tables already exist.** All four auto-playlist tables
   (`auto_playlist_brief`, `auto_playlist_result`, `auto_playlist_item`, `auto_playlist_rejection`)
   plus `playlist`/`playlist_item` and `smart_crate`/`crate_rule` were created in `dj_v1`
   (`Sources/DJ/Data/DJMigrations+v1.swift`) and their DDL matches §14.3 verbatim. Appendix M.4's
   `DJMigrations+v4.swift` is **not** needed; `DJSchema.migrationOrder` stays
   `["dj_v1", "dj_v2", "dj_v3"]`. What is missing is the row records: `AutoPlaylistBrief`,
   `AutoPlaylistResult`, `AutoPlaylistItem`, `AutoPlaylistRejection`, and — for the static save
   (FR-PLIST-7) — `DJPlaylist`/`DJPlaylistItem`. They land in `DJRecords.swift`.
2. **Energy is compared as an empirical-CDF percentile rank in [0, 1].** §28A.5 maps arcs onto the
   library's *own* energy distribution ("arc = 1.0 always means the most energetic thing that fits
   this brief"). So the generator converts each candidate's stored `track.energy` (0...10 scalar)
   to its percentile rank over the candidate set — deterministic, ties broken by `trackID` — and
   `arcError` compares that rank to `arc.value(at:)`. Missing energy → neutral 0.5 (the same
   missing-attribute convention as `RankCandidate`). `auto_playlist_item.targetEnergy` /
   `actualEnergy` store these [0,1] ranks. This is what makes AT-PLIST-4 (mean |actual − target|
   ≤ 0.15) and the mockup's "arc error 0.07" coherent.
3. **`camelotDistance` is derived from the existing graded `Camelot.compatibility`.**
   `camelotDistance(a, b) = 1 − Camelot.compatibility(a, b)`, in the `Camelot` enum, so there is
   exactly one scoring implementation (§49.3 invariant: no scoring logic exists twice) and
   `transitionCost` stays in [0, 1]. The spec's "0 for same/adjacent" (§28A.2) is approximate:
   same 0.0, relative maj/min 0.1, ±1 same-letter 0.3, energy-boost 0.5, else 1.0.
4. **`TrackFeatures` is a new pure value type.** §28A.2's cost terms need BPM, Camelot, energy,
   the pooled embedding (timbre) and the spacing fields; none of the existing types carry all of
   them (`DJTrackRow` has no embedding; `DJTrack` has no artistIDs). `TrackFeatures` carries:
   `trackID`, `durationSec`, `bpm`, `camelot`, `energy` (the [0,1] rank), `embedding` (dequantized
   f32 pooled vector from `track_embedding`), `artistIDs`, `albumID`, `isExplicit`,
   `isFullyCached`. Timbre continuity uses the stored vector; a missing embedding contributes
   neutral 0.5 (unanalysed tracks still sequence, they just cannot win on timbre).
5. **Sequence weights are pinned for determinism.** §28A.1's J uses `w_a/w_s/w_t/w_d` without
   defaults. Fix them as `SequenceWeights`: arc 0.25, semantic 0.35, transition 0.25, duration
   0.15 (sum 1.0). Spacing is a **hard** constraint (reject extensions that breach
   `minArtistGap`/`minAlbumGap`, per §28A.3 step 4), so `spacingPenalty(S)` is 0 for feasible
   sequences. `keyStrictness` scales the key term (0 = ignore key).
6. **Seeded tie-breaks (NFR-DET-1).** `brief.randomSeed` seeds a SplitMix64 PRNG; every tie among
   equal-scoring beam extensions and in the close-out swap resolves through it, so two devices
   with the same library + same brief + same seed produce the same playlist (AT-PLIST-6), and a
   fresh seed is what makes "regenerate" vary. This is deterministic random — same seed, same
   bytes — never ambient entropy.
7. **Candidate resolution.** `PlaylistGenerator` embeds the brief's prose (or, for an
   audio-seeded brief, reuses the seed track's pooled vector — skipping the text encoder, which is
   what makes AT-PLIST-2's ≤ 400 ms case *is* the beam plus a scan), scans the Tier A store for the
   top pool (P ≈ 8·N, capped 600, the existing `VectorStore.search`), applies the hard constraints
   (BPM range, genre, requireCached, allowExplicit) and subtracts `auto_playlist_rejection` rows.
   If the pool is short of `N`, widen the semantic pool and re-filter; if still short, generate
   what is possible and **say so** — never pad with tracks that don't fit (FR-PLIST-2 honesty).
8. **No LLM.** `BriefExtractor` is the ~200 deterministic lines of §28A.6: durations ("two hours"),
   track counts, BPM ranges, arc phrases from a fixed phrase table, and +/− vocal/explicit terms.
   Everything unrecognised still reaches CLAP unchanged (degrades to vibe search + a default arc),
   and the UI shows what was understood as editable chips (§41.6).
9. **The sync mapping is CloudKit-free in M3.** The `auto_playlist_brief` row already carries
   `syncID` and the full payload §38.2's `AutoPlaylistBrief` record carries (`prompt`, `arcKind`,
   `arcPoints`, `targetSeconds`, `constraintsJSON`, `seed`). `Sources/DJ/Sync/AutoPlaylistBriefMapping.swift`
   is a pure round-trip mapping of that payload (a Codable envelope), byte-exact tested — the
   repo's `RecordMapping` convention without CloudKit. The CKRecord translation and the
   `DJSyncService` wiring land in M6 with `DJRecordMapping` (Appendix M.7); importing CloudKit into
   the DJ core now would add a dependency or force a `#if os(watchOS)` (invariant §49.3.6). The
   *brief-syncs-not-the-track-list* intent (§38.2) is realised at the schema and pure-mapping level
   in M3. **No live CloudKit wiring in this milestone.**
10. **FR-PLIST-10's "Blend these" entry point is present but inert in M3.** StoreKit and the DJ
    product land in M4. The dismissible card renders per the mockups, states what DJ would do, is
    remembered per session (the MUST-NOT-reappear clause), and its button is an honest
    "coming in 3.0" — no StoreKit import (CI boundary), no fake paywall.
11. **The on-device numbers and the ears are user-owned.** AT-PLIST-2's ≤ 3 s / ≤ 400 ms on a real
    A-series device and AT-PLIST-7's blind listening check need a device and a human — the §50.3
    precedent from M2. The automated proxies land in this milestone's tests: a pure 30k-candidate
    beam benchmark (extrapolating under budget, alongside M2's 17.6 ms/30k scan) and the AT-PLIST-3
    shuffle-comparison harness on deterministic synthetic corpora.
12. **No new network host, no new dependency.** Everything is GRDB / Foundation / Accelerate /
    the existing CLAP seam — all already linked in `TonearmDJ`. The brief's prose goes to the
    already-shipped text encoder, never to a network.

## 3 · File manifest (Appendix M.4, paths indicative per handoff §6.4)

New directories: `Sources/DJ/Playlist/` (pure core), `Sources/DJ/Features/Playlist/` (views +
models), `Sources/DJ/Sync/` (mapping). Tests under `Tests/DJTests/`. `Sources/DJ` stays excluded
from the app target (handoff §2 trap), so DJ-only file additions need **no `xcodegen generate`**;
only a `project.yml` change would.

| File | Purpose |
|---|---|
| `Data/DJRecords.swift` (+6 records) | `AutoPlaylistBrief`, `AutoPlaylistResult`, `AutoPlaylistItem`, `AutoPlaylistRejection`, `DJPlaylist`, `DJPlaylistItem` (§14.3) |
| `Playlist/EnergyArc.swift` | `EnergyArc` — steady/build/peakAndRelease/windDown/wave/custom, closed-form `value(at:)`; `EmpiricalEnergyCDF` (deterministic percentile ranks) (§28A.5) |
| `Playlist/TransitionCost.swift` | `TrackFeatures`, `SequencingConstraints`, `SequenceWeights`, `camelotDistance` (via `Camelot.compatibility`), pure `transitionCost` (§28A.2) |
| `Playlist/PlaylistSequencer.swift` | pure beam search, diversity guard, spacing hard filter, duration-aware extension + close-out swap (§28A.3); `PlaylistBrief`, `SequencedSlot` domain types |
| `Playlist/BriefExtractor.swift` | deterministic ~200-line extractor: durations, counts, BPM, arc phrases, +/− terms; editable-chip model (§28A.6) |
| `Playlist/PlaylistGenerator.swift` | actor: resolve candidates → CDF ranks → `sequence` → persist brief/result/items; lock / reject / replace / reshuffle / extend (§28A.4) |
| `Features/Playlist/PlaylistBriefView.swift` + `AutoPlaylistModel.swift` | mockups `ipad/05a`, `iphone/03` (§41.6, §42.4) |
| `Features/Playlist/PlaylistResultView.swift` (+ model) | arc plot, per-transition badges, lock/replace/reject, save, extend/reshuffle (§41.7, mockup `ipad/05b`) |
| `Sync/AutoPlaylistBriefMapping.swift` | pure §38.2 `AutoPlaylistBrief` payload round-trip, byte-exact (§2.9) |
| `Tests/DJTests/{ArcTests,TransitionCostTests,SequencerTests,BriefExtractorTests,PlaylistGeneratorTests,ShuffleComparisonTests}.swift` | AT-PLIST-1..6 (§28A.7) |

## 4 · Data layer — no new migration (tables exist in `dj_v1`)

All M3 tables are already live. What lands in `DJRecords.swift` is the row types (snake_case
tables, camelCase columns, matching the existing record style):

- `AutoPlaylistBrief` (id, syncID, prompt, arcKind, arcPointsJSON, targetSeconds, targetTrackCount,
  constraintsJSON, seedTrackID, seedCrateID, randomSeed, createdAt, updatedAt) — `constraintsJSON`
  is the canonical `.sortedKeys` encoding of `SequencingConstraints` (byte-exact round-trip, like
  `VibeQuery.encodedJSONString()`).
- `AutoPlaylistResult` (id, briefID, playlistID, smartCrateID, generatedAt, totalSeconds, arcError,
  meanTransitionCost, analysisVersion) — `analysisVersion = AnalysisVersions.embedding`.
- `AutoPlaylistItem` (id, resultID, trackID, position, locked, targetEnergy, actualEnergy,
  transitionCostIn, semanticScore) — `targetEnergy`/`actualEnergy` are the [0,1] CDF ranks (§2.2).
- `AutoPlaylistRejection` (id, briefID, trackID, rejectedAt) — unique on (briefID, trackID).
- `DJPlaylist` / `DJPlaylistItem` — the static-save rows for FR-PLIST-7.

## 5 · Commit sequence (Appendix M.4)

### Commit 3.1 — arcs + transition cost, pure, golden-tested

- `Playlist/EnergyArc.swift`: the six cases with closed-form `value(at t: Double) -> Double`
  (steady flat; build S-curve; peakAndRelease with `peakAt`; windDown; wave with `cycles`;
  custom linearly interpolated points), all normalized to [0,1] and deterministic (NFR-DET-3).
  `EmpiricalEnergyCDF` — sort + rank over a candidate set's energies, ties by `trackID`, missing
  energy → 0.5 (§2.2).
- `Playlist/TransitionCost.swift`: `TrackFeatures` (§2.4), `SequencingConstraints` (§28A.2,
  Codable with `.sortedKeys`), `SequenceWeights` (§2.5), `camelotDistance` added to the `Camelot`
  enum (§2.3), and the pure `transitionCost(_:_:_:)` = 0.30·bpm + 0.25·key + 0.30·timbre +
  0.15·energy, drops penalised harder than rises (§28A.2's asymmetric energy step).
- Tests: `ArcTests` (golden values for each preset at t = 0 / 0.5 / 1; custom interpolation;
  determinism; CDF mapping edge cases), `TransitionCostTests` (weight composition, drop-harder-
  than-rise, keyStrictness scaling, timbre from two known embeddings, determinism).
  **FR-PLIST-3/4/5, NFR-DET-3.**

### Commit 3.2 — beam sequencer + duration close-out

- `Playlist/PlaylistSequencer.swift` + the `PlaylistBrief` / `SequencedSlot` domain types.
  `sequence(candidates:brief:seed:)` per §28A.3: seed the beam with the K best by arc+semantic
  (K = 24), extend slot by slot considering the M best next candidates (M = 32) scored by running
  J with a duration-aware term that engages once Σduration is within one track of `T`, keep the
  best K with the last-two-tracks diversity guard, honour locks (a locked slot admits exactly one
  candidate) and spacing (hard reject), then finish with the duration close-out: if |duration − T|
  > 5%, swap the single track whose replacement best closes the gap without raising J by more than
  ε — this is what delivers FR-PLIST-2. All ties through the seeded SplitMix64 PRNG (§2.6).
- Tests: `SequencerTests` — **AT-PLIST-1** (duration within ±5% for 20 briefs × 3 library sizes),
  **AT-PLIST-4** (mean arc error ≤ 0.15 for all five preset arcs), **AT-PLIST-5** (1,000 seeded
  generations: no duplicates, no spacing breach, no rejected track, every lock honoured),
  **AT-PLIST-6** (same brief + seed + library ⇒ byte-identical `SequencedSlot` rows), and a pure
  benchmark at 30k synthetic candidates extrapolating under the 3 s / 400 ms budget (recorded in
  §9; the real-device number is user-owned, §2.11). **FR-PLIST-1/2/3/4/6, NFR-DET-1/3.**

### Commit 3.3 — brief extractor + persistence + the generator actor + sync mapping

- `Playlist/BriefExtractor.swift` (§2.8): durations/counts/BPM ranges, the arc phrase table
  ("starts mellow and ends euphoric" → peakAndRelease, "wind down" → windDown, "for studying" →
  steady), +/− vocal/explicit terms, and a chip model the UI edits. Unparsed prose is **not** an
  error — it still reaches CLAP unchanged.
- `DJRecords.swift`: the six records (§4). A small `AutoPlaylistRepository`: persist
  brief + result + items + rejections in one transaction; load a brief's last result with its
  items; upsert rejections.
- `Playlist/PlaylistGenerator.swift`: the actor (`generate` / `replaceSlot` / `reject` / `extend`,
  plus reshuffle). `generate` resolves candidates per §2.7 (seed-track vector for audio-seeded
  briefs, else the brief text through `CLAPEmbedder`; Tier A pool; hard constraints; subtract
  rejections; CDF ranks; honest short-pool state), calls the pure `sequence`, and persists. A
  rejection is written then re-runs with the remaining locks intact; replace re-runs that slot
  only; extend re-parameterises the arc over the new length.
- `Sync/AutoPlaylistBriefMapping.swift`: the pure payload round-trip (§2.9).
- Tests: `BriefExtractorTests` (durations/counts/BPM/arc phrases/± terms; unrecognised text
  passes through; chip round-trip), `PlaylistGeneratorTests` (fake embedder end-to-end;
  brief→sequence→persist atomicity; rejection exclusion; locks honoured on regenerate; honest
  short-pool state; byte-exact `constraintsJSON`/mapping round-trips).
  **FR-PLIST-1/2/6/7/8, NFR-DET-1/2/3.**

### Commit 3.4 — brief and result UI on both size classes

- `Features/Playlist/AutoPlaylistModel.swift` + `PlaylistBriefView.swift` (mockups `ipad/05a`,
  `iphone/03`, §41.6, §42.4): the brief field with the editable "what we understood" chips, the
  energy-arc picker (six presets incl. draw-your-own, peak marker draggable), length
  (duration slider with ±5% honesty, or track count), the constraint toggles (spacing, BPM jump,
  key continuity, cached-only, explicit), and "start from" a seed track or crate. Generation runs
  the generator; the phone and iPad share the one model.
- `Features/Playlist/PlaylistResultView.swift` (+ model, mockup `ipad/05b`, §41.7): the sequence
  plotted against the requested arc (requested vs delivered, arc-error chip), per-transition
  badges (key relationship + BPM delta, roughest joins visible), per-row lock 🔒 / replace ⟳ /
  reject ✕, footer with total-vs-target and the AT-PLIST-3 language ("52% smoother than shuffle"),
  Save as Playlist / Save as Smart Crate (the brief → `VibeQuery` → `SmartCrateRepository`),
  Extend +30 min, Reshuffle the middle, and the dismissible inert "Blend these" card (§2.10).
  Wired from the Library screen ("Make a playlist"), mirroring the Vibe Search entry.
- Tests: `AutoPlaylistModelTests` (a fake-generator seam mirroring `VibeSearching`; states —
  generating / result / honest-short-pool; save-as-crate; session dismissal of the card).
  **FR-PLIST-4/5/6/7/10.**

### Commit 3.5 — the AT-PLIST-3 shuffle-comparison harness + final gates

- `Tests/DJTests/ShuffleComparisonTests.swift`: for each synthetic corpus, mean `transitionCost`
  of the generated sequence is **≥ 40% lower** than the mean over seeded random permutations of
  the *same track set* — the test that proves the sequencer optimises and is not merely a filter
  (§28A.7, AT-PLIST-3).
- Final gate sweep: AT-PLIST-1..6 green on the same corpora, full `make test-swift` green, app
  builds. UI regression lanes stay app-smoke only (M2 convention — the generated-playlist screens
  are covered by `AutoPlaylistModelTests`/`PlaylistGeneratorTests`). The blind listening check
  (AT-PLIST-7) is the user-owned ship gate (§2.11).

## 6 · Testing strategy (spec §47, Appendix R)

- **Kernels (pure):** arcs, CDF mapping, transition cost, beam search — synthetic inputs from
  Appendix R.1 conventions, golden-pinned, deterministic (NFR-DET-3). Seeded PRNG means the
  sequencer's "random" is byte-reproducible (AT-PLIST-6).
- **Fake-embedder end-to-end:** the deterministic `DeterministicFakeSemanticModel` drives
  generator → persistence → result in tests, so every FR-PLIST behaviour is exercised without any
  model weights (the M2 convention).
- **Store/DB:** `PlaylistGeneratorTests`/repository tests against a temp database (mirroring
  `DJDatabaseTests`/`DJLibraryStoreTests` conventions); the Tier A store is already covered by M2.
- **UI:** `AutoPlaylistModelTests` against a fake generator; the screens are covered by model tests
  and the app-smoke lane, exactly as Vibe Search was. UI regression lanes (§53) are **not**
  extended in M3.

## 7 · Definition of done (per commit, §49.4)

Tests green · acceptance IDs named in the message · no new dependency without an Appendix Q entry
(none) · no new network host (none) · mockup coverage contract satisfied (mockups `ipad/05a-b`,
`iphone/03` already exist) · no `xcodegen generate` needed for DJ-only files (§3) · CHANGELOG
entry noting the tier (free).

## 8 · Session protocol

One commit per numbered task (3.1–3.5), each a fresh session reading this plan + the spec
sections the commit names. Commit on `main`, allow ~5 min for the pre-commit suite. **Ask before
pushing** (push triggers CI + TestFlight). No `Co-Authored-By` trailer (owner preference).

## 9 · Implementation Audit

_To be filled in as commits land: files changed, tests run, intentional deviations._

| Commit | Status | Notes |
|---|---|---|
| Plan doc | pending | `docs/plans/dj-phase-3-autoplaylists.md` |
| 3.1 arcs + transition cost | pending | |
| 3.2 beam sequencer + duration close-out | pending | |
| 3.3 brief extractor + persistence + generator + sync mapping | pending | |
| 3.4 brief + result UI, both size classes | pending | |
| 3.5 AT-PLIST-3 harness + final gates | pending | |

**Open items owned by the user:** the AT-PLIST-2 on-device generation-time measurement (≤ 3 s text
/ ≤ 400 ms audio-seeded at 30k on an A-series device), the AT-PLIST-7 blind listening check
(generated sequence beats shuffle over the same track set), and the ship gate for the 2.1 free
release.
