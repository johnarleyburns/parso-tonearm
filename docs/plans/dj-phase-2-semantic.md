# DJ Phase 2 — Semantic search, Stage 2 embeddings, and the tiered vector store (Milestone M2)

Plan for milestone **M2** of the Platterhead iOS DJ build. Implementation is driven by this file
one commit at a time, on `main`, per handoff §8 and the working agreement in
`docs/plans/tonearm-mvp-ios/HANDOFF.md`.

**Spec:** `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`. Read §48.3 (goal/exit),
Appendix M.3 (manifest), and the sections each commit names. **Appendix M.3's commit order is
authoritative; §49.2's implementation order (schema → pure kernels → façade → view model → view)
is binding.** §16 supersedes Appendix G wherever they disagree (spec G.4, "§16 is normative").

## 1 · Milestone goal and exit (spec §48.3)

CLAP semantic embeddings (Stage 2 analysis): log-mel preprocessing, Core ML audio/text encoders
(music-domain CLAP, FP16, ANE), 10 s overlapping windowed embedding, attention/mean pooling to one
int8-quantized whole-track vector per track, a tiered vector store (vDSP brute-force Tier A ≤
30k tracks; sqlite-vec Tier B above), hybrid ranking, and the free-tier **Vibe Search** UI
(mockups `ipad/04a`, `ipad/04b`, `iphone/02`) with smart-crate save.

**Exit (§48.3):** FR-SEM-3 met (query latency ≤ 120 ms at 30k tracks on an A17-class device),
coverage-honest results (FR-SEM-8), and the whole thing works in airplane mode once the model is
downloaded. FR-SEM-1..8, AT-SEARCH-\*, AT-SEM-6. `make test-swift` green; app builds;
`xcodegen generate` committed after any file add/remove.

## 2 · Resolved spec-vs-repo decisions (recorded up front)

1. **The model seam — real CLAP weights are in-repo.** §27.1/Appendix D assumes converted
   `.mlpackage` files produced by a tools repo; they now exist: the official LAION-CLAP music
   checkpoint (`lukewys/laion_clap` → `music_audioset_epoch_15_esc_90.14.pt`, HTSAT-base,
   Apache-2.0) is converted (FP16) and verified (audio cosine ≥ 0.9997, text ≥ 0.9999,
   cross-modal retrieval intact) into `Resources/Models/CLAPAudioEncoder.mlpackage` (137 MB,
   ODR `clap-audio`) and `Resources/Models/CLAPTextEncoder.mlpackage` (240 MB, ODR `clap-text`);
   the mel filterbank + RoBERTa vocab/merges live bundled in `Resources/CLAP/`. Reproduction
   tooling is in `tools/clap-coreml/`. **`CLAPEmbedder` still talks to a `SemanticModel`
   protocol** with two conformances: `CoreMLSemanticModel` (loads `.mlpackage` from an
   ODR-provided URL; compiles and ships, but reports "not available" until the tag is fetched —
   which is exactly the FR-SEM-6 behaviour) and `DeterministicFakeSemanticModel` (seeded,
   hash-based pseudo-embedding, **tests and goldens only**, never production). Everything below
   the protocol — preprocess, pooling, quantization, store, search, UI — is identical for both.
   Production without tags is the required degradation (fully functional, semantic features
   disabled, honest UI), exercised in tests. **The `embedding` stage version lands at 1 in commit
   2.1** because an implementation can now run it, and `AnalysisVersions`' long-standing
   exclusion is lifted.
2. **`vectors.i8` layout — §15.7a is referenced (§16.2, §16.7, G.4) but never defined.** Define
   it here, following §15.7 conventions: a single append-only file at
   `Caches/TonearmDJ/vectors.i8`, row-major `Int8[dims]`, no header, dims from
   `vector_matrix_meta.dims`; memory-mapped read-only for scans; row `r` ↔
   `track_embedding.matrixRow = r`; tombstoning = set `matrixRow` NULL (row skipped, dead space);
   compaction rewrites the file and remaps rows when tombstones exceed 20%, resumable (§16.7).
3. **No local device → the §50.3/§16.6 measurements are delegated, not skipped.** A benchmark
   test in 2.2 builds a 30k × 512 int8 matrix and times the vDSP scan (reported as ns/row in the
   audit table). The A17 real-device number that decides Tier B is user-owned (first TestFlight
   build). **Commit 2.6 (Tier B sqlite-vec) is deferred pending that number**; Tier A is the
   shipped default per §16.1, and `CSQLiteVec` already links (§9.1) for whenever Tier B lands.
   The §16.6 recall@10 ≥ 0.95 gate is tested in 2.3 against f32 ground truth on synthetic data
   (commit 2.3), with f16 as the documented fallback.
4. **`dj_v3` migration.** `smart_crate`/`crate_rule` already exist in `dj_v1`; the dj_v2 analysis
   tables shipped in M1. The embedding tables (§15.4) go in a new append-only `dj_v3` and
   `DJSchema.migrationOrder` becomes `["dj_v1", "dj_v2", "dj_v3"]`. No existing table changes.
5. **Preprocessing parameters are model-specified.** `Preprocess` is a pure
   `(PCMBuffer, EmbeddingModelSpec) → [MelWindow]`; the spec (sample rate, FFT/mel params,
   window/hop seconds) comes from the active model. The real model's spec (from
   `model_spec.json`, `tools/clap-coreml/`) is: 48 kHz, 10 s window / 5 s hop, FFT 1024 / hop 480,
   **64 librosa-slaney mel bins over 50–14000 Hz**, 1001 frames, 512-D L2-normed embeddings,
   text max length 77. The fake uses a fixed deterministic spec and goldens pin it; the real
   spec replaces it in commit 2.1 with an `embedding_version` bump if ever changed (§27.1).
6. **The embedding stage is governor-gated and availability-gated.** The coordinator runs the
   `.embeddings` lane only when the audio model is actually available (`ModelResourceService`),
   and never enqueues tracks whose `embeddingVersion` is current. The ANE serializes predictions
   (§27.1), so the embedding lane is concurrency-1 on the encoder even though preprocess
   pipelines ahead of it.
7. **No new network host, no new dependency.** Everything below is vDSP/CoreML/GRDB/Foundation —
   all already linked in `TonearmDJ`. `NSBundleResourceRequest` is system API. Models come from
   ODR (Apple's infrastructure), never a bespoke host.

## 3 · File manifest (Appendix M.3, paths indicative per handoff §6.4)

New directories: `Sources/DJ/Semantic/` and `Sources/DJ/Features/VibeSearch/`. Tests under
`Tests/DJTests/`. `Sources/DJ` stays excluded from the app target (handoff §2 trap).

| File | Purpose |
|---|---|
| `Data/DJMigrations+v3.swift` | `dj_v3` DDL: `embedding_version`, `track_embedding`, `window_embedding`, `vector_matrix_meta` (§15.4) |
| `Semantic/Preprocess.swift` | resample → log-mel, deterministic, model-spec-driven (§27.2) |
| `Semantic/EmbeddingModel.swift` | `EmbeddingModelSpec`, `SemanticModel` protocol, `CoreMLSemanticModel`, `DeterministicFakeSemanticModel` |
| `Semantic/CLAPEmbedder.swift` | actor serializing audio/text predictions, L2-normalizes (§27.1) |
| `Semantic/ModelResourceService.swift` | ODR leases/retention, progress stream, honest absence (§27.1a, FR-SEM-6) |
| `Semantic/Pooling.swift` | window→track mean/attention pooling, streaming accumulator (App. G.3, §27.4) |
| `Semantic/Quantization.swift` | symmetric per-row int8 quantize/dequantize (§16.6) |
| `Semantic/VectorStore.swift` | Tier A `vectors.i8` mmap scan + lifecycle; façade `VectorStore` (§16.2, §16.7) |
| `Semantic/Ranking.swift` | pure hybrid scorer + `RankBreakdown` (§28.1, App. G.5) |
| `Semantic/SemanticSearchService.swift` | text + audio-to-audio query, refine terms, coverage (§27.5, FR-SEM-7/8) |
| `Features/VibeSearch/VibeSearchModel.swift` + `VibeSearchView.swift` | mockups `ipad/04a-b`, `iphone/02` (§41.4–41.5, §42.3) |
| `Data/DJRecords.swift` (+`SmartCrate`/`CrateRule`/embedding records) | row types for the new tables |
| `Tests/DJTests/{Preprocess,Pooling,Quantization,VectorStoreTierA,Ranking,SemanticSearch,ModelResourceService,RecallGate,SearchModel,SmartCrate,EmbeddingCoordinator}Tests.swift` | unit + golden + acceptance tests |

## 4 · Data layer — `dj_v3` migration (commit 2.1, schema first per §49.2)

Append `"dj_v3"` to `DJSchema.migrationOrder`; register `DJMigrations.registerV3`. Tables per
§15.4 (snake_case tables, camelCase columns, matching v1/v2 style):

- `embedding_version` (version PK, modelName, dimensions, windowSeconds, hopSeconds, pooling,
  introducedAt)
- `track_embedding` (trackID PK → track cascade, dims, vector BLOB = Int8[dims], scale, matrixRow
  NULL when tombstoned, version) + index on matrixRow
- `window_embedding` (id PK, trackID → cascade, windowIndex, startSample, endSample, vector,
  scale, version) + index (trackID, windowIndex) — crate-scoped; rows exist only while a crate
  referencing the track is prepared (§16.4)
- `vector_matrix_meta` (id PK = 1, rowCount, tombstoneCount, dims, tier, lastCompactedAt)

BLOB semantics per §15.7: embedding vectors are **raw `Int8[dims]`**, L2-normalized-then-quantized,
little-endian, no header (dims from the row). `track_embedding.vector` is the source of truth; the
matrix is a derived index rebuilt from it on version change (§16.7).

## 5 · Commit sequence (Appendix M.3)

### Commit 2.1 — schema + preprocess + model seam + ODR delivery

- `DJMigrations+v3.swift` (§4) + `DJSchema.migrationOrder` → `["dj_v1", "dj_v2", "dj_v3"]`.
- `Semantic/Preprocess.swift`: `EmbeddingModelSpec` (sampleRate, fftSize, hopSize, melBins,
  lowHz, highHz, windowSeconds, hopSeconds) and a pure `Preprocess.logMel(pcm, spec)` →
  `[MelWindow]` (resample via `AVAudioConverter`, vDSP mel filterbank over the existing STFT
  machinery). Deterministic (NFR-DET-3), golden-tested.
- `Semantic/EmbeddingModel.swift`: `SemanticModel` protocol (`embedText(_:)`, `embedAudio(mel:)`,
  `spec`); `CoreMLSemanticModel` (loads `MLModel` from a URL, `computeUnits = .cpuAndNeuralEngine`,
  "not available" before/without a real file) and `DeterministicFakeSemanticModel` (seeded
  SHA-256-based pseudo-embedding, L2-normalized, **test-only**).
- `Semantic/CLAPEmbedder.swift`: actor serializing predictions; `embedText` → 512-D L2-norm;
  `embedWindows` → `[512-D]`; exposes the active model spec.
- `Semantic/ModelResourceService.swift`: actor owning `NSBundleResourceRequest` for tags
  `clap-text`/`clap-audio`; lease/retain/release; progress `AsyncStream`; a purge re-requests
  transparently; absence is never an error (FR-SEM-6). Test seam: an injected availability source
  so tests treat tags as present/absent deterministically (macOS `swift test` has no ODR system).
- `AnalysisVersions.embedding = 1` + descriptor; seed the `embedding_version` registry row
  (modelName from the active provider; dims 512; window 10 s; hop 5 s; pooling `attention`).
- **ODR tags:** declare `clap-text` + `clap-audio` on the app target (project.yml / Info.plist)
  so `NSBundleResourceRequest` is wired; `xcodegen generate` and commit. The tags **carry content**
  (the converted `Resources/Models/*.mlpackage` from this plan's §2.1); tests still treat tags as
  present/absent deterministically (macOS `swift test` has no ODR system).
- Tests: `PreprocessTests` (golden log-mel for a synthetic signal; spec-parameter determinism),
  `FakeEmbeddingTests` (determinism, L2 unit norm, seed stability), `ModelResourceServiceTests`
  (absent tag → honest state, lease/release, progress, re-request after purge),
  `MigrationV3Tests` (append-only order, tables created, `embedding_version` seeded,
  `track_embedding` round-trip). **FR-SEM-6, AT-SEM-6 (absent-tag suite shape), NFR-DET-3.**

### Commit 2.2 — Tier A store + pooling + analysis upsert, measured at 30k

- `Semantic/Quantization.swift`: symmetric per-row int8, `scale = max/127`, no zero-point
  (§16.6); dequantize. Pure, vDSP.
- `Semantic/Pooling.swift`: streaming accumulator; mean pooling + heuristic attention (softmax
  over salience = energy blend + distance-from-centroid, §27.4); L2 renormalize.
- `Semantic/VectorStore.swift`: `VectorStore` façade; **Tier A** implementation: append-only
  `vectors.i8` under `DJDatabase.cachesDirectory` (§13.1), mmap'd read-only scans
  (`vDSP_vflt8` block convert + `vDSP_dotpr`, fixed-min-heap top-K, cancellable between blocks,
  per §16.2); upsert appends the row and writes `track_embedding` + `vector_matrix_meta` in one
  transaction; delete tombstones (`matrixRow = NULL`); compaction when tombstones > 20%,
  resumable (§16.7).
- **Coordinator integration:** `AnalyzePipeline.embed(url:)` (decode → preprocess → encode →
  pool) and an `AnalysisCoordinator` embedding lane: `reconcileEmbeddings()` enqueues tracks with
  `embeddingVersion < 1` only when the audio model is available; runs under governor lane
  `.embeddings` (concurrency-1 on the encoder, §2.6), pauses while a performance is live
  (FR-ANL-2), and persists `track_embedding` + matrix append + `track.embeddingVersion = 1` in
  one transaction. `SemanticSearchService.indexDidChange(trackIDs:)` hook stubbed for 2.4.
- **Benchmark:** a test generates a 30k × 512 int8 matrix and times the scan, asserting it stays
  inside a per-row budget that extrapolates under the 120 ms FR-SEM-3 target (recorded in §9;
  the real-device number is user-owned).
- Tests: `QuantizationTests` (round-trip, symmetric, clamp), `PoolingTests` (mean/attention,
  golden salience), `VectorStoreTierATests` (upsert/scan/delete/tombstone/compact round-trip,
  **byte-identical regeneration** for NFR-DET-3, cancellation), `EmbeddingCoordinatorTests`
  (version reconcile enqueues only stale tracks; availability gate; single-transaction persist;
  governor lane respected). **FR-SEM-1/6/8, FR-ANL-2/3/7/8, NFR-DET-3.**

### Commit 2.3 — the §16.6 quantization gate (recall@10 ≥ 0.95)

- `Tests/DJTests/RecallGateTests.swift`: build f32 ground-truth unit vectors (≥ 1,000 rows, ≥ 200
  queries), quantize to int8, compute recall@10 against the exact f32 cosine ranking; assert
  **≥ 0.95**. If the gate fails on the synthetic corpus, the fallback is f16 (§16.6) — recorded in
  §9. Also asserts quantization is deterministic and version-stable.
- No production code changes; this is the measurement gate the spec demands before search ships.
- **AT-SEARCH-\*, NFR-DET-3.**

### Commit 2.4 — hybrid ranking + SemanticSearchService (text + audio-to-audio + refine)

- `Semantic/Ranking.swift`: pure scorer per §28.1/App. G.5 — `RankWeights` (0.40/0.20/0.20/0.10/
  0.10), `bpmFit` (gaussian over ±tolerance), `keyFit` reusing `Camelot.compatibility` (graded
  1.0/0.9/0.7/0.5/0.0, Appendix B), `energyFit`, `phraseFit`, `fusedScore`, and `RankBreakdown`
  for the UI's "why it matched" decomposition (§41.5).
- `Semantic/SemanticSearchService.swift`: façade. Text query (embed → Tier A top-pool → Swift
  hybrid re-rank, the same pure functions the SQL functions would wrap, §16.5); **audio-to-audio**
  ("more like this", FR-SEM-7) uses the track's stored pooled vector and excludes itself;
  refinement terms (+/−) add/subtract text embeddings and renormalize the query vector
  (FR-SEM-4); coverage = indexed ÷ total tracks, honest (FR-SEM-8); `indexDidChange` warms caches.
- Tests: `RankingTests` (weighted composition, graded Camelot reuse, tie handling, `RankBreakdown`
  decomposition), `SemanticSearchServiceTests` (fake embedder end-to-end: text query ranks stored
  tracks; audio-to-audio excludes self; +/− terms shift results deterministically; coverage
  honesty with a partially-indexed store; empty/absent-model returns a stated state, never a lie).
  **FR-SEM-1/2/4/7/8, AT-SEARCH-\*.**

### Commit 2.5 — Vibe Search UI + smart-crate save

- `Features/VibeSearch/VibeSearchModel.swift` + `VibeSearchView.swift` (mockups `ipad/04a-b`,
  `iphone/02`): free tier; query state with the privacy line on first use (NFR-PRIV-5), suggestion
  chips seeded from the library's own descriptor distribution, honest coverage footer (FR-SEM-8);
  results state with the hybrid score decomposed per row (FR-SEM-2), +/− refinement chips
  (FR-SEM-4), latency breakdown, actions (Play · Queue · Save as Smart Crate); a **model-not-
  downloaded state** that states it plainly and offers the ODR fetch, never silent empty results
  (FR-SEM-6). **Query debounce 250 ms with in-flight cancel** (§27.5). Wired from the Library
  screen; "More like this" on track rows (audio-to-audio).
- `SmartCrate`/`CrateRule` row records + a small repository: save a `VibeQuery` as
  `smart_crate.queryJSON` (+ normalized `crate_rule` rows); a crate re-evaluates live (FR-SEM-5).
- Tests: `SearchModelTests` (debounce, cancel, coverage, model-absent state, chip seeding),
  `SmartCrateTests` (save/load/re-evaluate; query round-trips byte-exact). **FR-SEM-2/4/5/6/8,
  NFR-PRIV-5.**

### Commit 2.6 — Tier B sqlite-vec (**deferred — only if 2.2's measurement says Tier A fails**)

Per §16.1 and §50.3, Tier B is validated *before* it is built: if the 2.2 scan benchmark stays
inside budget at the sizes real users have, the ANN index is deferrable indefinitely. The A17
real-device number is user-owned (TestFlight), so **this commit is blocked on §50.3's measurement
and is not attempted in this milestone.** When it does land: `VecExtension.register()` before the
first connection (§16.3 — the debug assertion), `vec_track`/`vec_window` virtual tables created in
a `dj_v4` migration, hybrid query as one SQL statement (§16.5), and **AT-SEARCH-5** asserting Tier
A and Tier B return identical orderings on the same fixture. `CSQLiteVec` already compiles in.

## 6 · Testing strategy (spec §47, Appendix R)

- **Kernels (pure):** preprocess, pooling, quantization, ranking — synthetic inputs from
  Appendix R.1 conventions, exact within tolerance, golden-pinned. Determinism is the gate
  (NFR-DET-3): same input twice → byte-identical bytes.
- **Fake-model end-to-end:** the deterministic fake embedder drives the full text → search →
  smart-crate path in tests, so every acceptance behaviour is exercised without any model weights.
- **Store:** `VectorStoreTierATests` against a temp `Caches` dir and temp database (mirroring
  `DJLibraryStoreTests` conventions); no device required.
- **ODR/absent model:** `ModelResourceServiceTests` with an injected availability source; the
  AT-SEM-6 shape (full suite green with tags absent) is covered by the service + search tests.
- UI regression lanes (§53) are **not** extended in M2; the Vibe Search screens are covered by
  `SearchModelTests`/`SmartCrateTests` and the app-smoke lane unchanged.

## 7 · Definition of done (per commit, §49.4)

Tests green · acceptance IDs named in the message · no new dependency without an Appendix Q entry
(none) · no new network host (none) · mockup coverage contract satisfied · `xcodegen generate`
committed whenever a file is added · CHANGELOG entry noting the tier (free).

## 8 · Session protocol

One commit per numbered task (2.1–2.5; 2.6 deferred), each a fresh session reading this plan +
the spec sections the commit names. Commit on `main`, allow ~5 min for the pre-commit suite.
**Ask before pushing** (push triggers CI + TestFlight). No `Co-Authored-By` trailer (owner
preference).

## 9 · Implementation Audit

_To be filled in as commits land: files changed, tests run, intentional deviations._

| Commit | Status | Notes |
|---|---|---|
| Plan doc | pending | `docs/plans/dj-phase-2-semantic.md` |
| Model conversion (§2.1) | done | real weights in-repo + verified (audio cos ≥ 0.9997, text ≥ 0.9999, retrieval intact); `tools/clap-coreml/`, ODR tags wired |
| 2.1 schema+preprocess+model seam+ODR | pending | |
| 2.2 Tier A store+pooling+upsert | pending | benchmark ns/row → decides 2.6 |
| 2.3 recall@10 ≥ 0.95 gate | pending | fallback f16 if it fails |
| 2.4 ranking+search service | pending | |
| 2.5 Vibe Search UI+smart crates | pending | |
| 2.6 Tier B sqlite-vec | deferred | blocked on §50.3 real-device measurement (user-owned) |

**Open items owned by the user:** the A17 real-device FR-SEM-3/§50.3 measurement that settles
Tier B. Until then the shipping posture is Tier A with honest absence states — exactly §16.1 and
FR-SEM-6. (Model weights are no longer an open item; they are in-repo as ODR content.)
