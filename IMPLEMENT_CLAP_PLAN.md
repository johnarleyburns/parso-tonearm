# Implement unified-library CLAP indexing and search

Status: implementation handoff; in progress. Written 2026-09-09.

**Amendment 2026-09-10 (owner):** This plan unifies the *database* only. The DJ
tab, the DJ mixer and the whole DJ interface/navigation are **retained** — they
are not being removed. "Retire the separate catalog" (C02) means: delete the
separate DJ *database* (`DJLibraryStore`/`DJDatabase`/`DJSchema` and its
`.sqlite`) and re-point every DJ feature at the one core `LibraryStore`
database. It does **not** mean removing DJ screens, decks, the workspace/mixer,
or DJ routes. Any earlier "authorized mixer removal" language below is
superseded and does not apply. Existing DJ-only data (hot cues, manual
beatgrids/grid corrections, crates/setlists, mix/recording history) is
intentionally **not migrated** — only data that re-derives from the core
library (BPM/key/energy/embeddings via the discovery pipeline) is preserved.

## 1. Assignment and authority

Implement this entire plan in the current repository. It is intended to be executable by a coding agent without additional product research or decisions from the owner. Read the named files to implement against actual signatures; repository inspection and SDK/compiler documentation are normal implementation work, not a reason to stop and request a new design.

The owner's requirements are authoritative:

1. ONE music database: the existing core `LibraryStore` database. No separate DJ music database, duplicate catalog, or track-ID bridge. Search uses core track IDs directly. The DJ tab, mixer and interface stay; DJ features read and write the one core database.
2. Imports automatically feed durable indexing. Decode, preprocessing, inference, hashing and vector retrieval MUST NOT run on the UI thread. Work resumes after suspension, termination and relaunch, progresses conservatively, and exposes persisted status.
3. Fix retrieval correctness, scope, cancellation and availability gaps.
4. Human assessment of musical retrieval quality happens AFTER implementation and the TestFlight build is uploaded. Do not stop implementation waiting for a curated corpus, owner relevance judgments or device benchmark results.

This document supersedes conflicting database, migration and CLAP instructions in `RECOMMENDATIONS_AGENT_PLAN.md`, `RECOMMENDATIONS.md` and historical DJ plans. In particular, delete the proposed two-catalog bridge requirement from the active preparation plan when updating documentation. The separate DJ *database* is abandoned: do not migrate its tracks, queues, cues, recordings metadata or analysis. Preserve the CORE library and its existing user data. Do not erase the core database, media files, or source credentials. Leave abandoned DJ database files inert rather than adding a destructive disk cleanup routine.

The DJ tab, DJ mixer and DJ interface are retained (see the 2026-09-10 amendment). There is no mixer removal. Re-point every DJ-only route/service that currently talks to the separate DJ database at the core `LibraryStore` database and the discovery side tables instead; keep the DJ UI, decks and workspace working. Preserve and port useful search, analysis, playlist generation and preparation consumers to the core catalog. Do not implement the entire unrelated preparation/paywall redesign as part of this assignment. No Apple Foundation Models, LLM interpreter, Jamendo/TIDAL discovery integration, new macOS app, cloud embedding service, new ANN backend or model training.

Follow `CLAUDE.md`: Swift 6 strict concurrency, work on main, mandatory commit hooks, no credential commits. A failing or unavailable toolchain is a reported blocker, never a passing test. This document does not authorize a push: obey the repository's ask-before-push rule unless the owner separately authorizes it. Finish code and checks before that approval gate. Human evaluation is not a pre-push gate.

## 2. Verified starting point

| Area | Current code and consequence |
|---|---|
| Canonical catalog | `Sources/Data/LibraryStore.swift`: actor, `DatabaseQueue`, Application Support/Tonearm/library.sqlite; `Records.swift`: Track/Asset/Source/playlist models. Keep this database and its IDs/syncIDs. |
| Core migrations | `Sources/Data/Schema.swift`: v1–v17 at writing; debug erase-on-schema-change enabled. Append migrations; disable automatic erase in application configurations. |
| Separate catalog | `Sources/DJ/Domain/DJLibraryStore.swift`, `Sources/DJ/Data/DJSchema.swift`, DJRecords and PlaylistCrateImporter. Eliminate the separate runtime database and duplicate imports. |
| Embedding pipeline | `Sources/DJ/Analysis/AnalysisCoordinator.swift`: `AnalyzePipeline.embed` decodes the entire file, builds all windows and then embeds. This is not the bounded-memory mobile implementation required here. |
| Worker | `Sources/DJ/Semantic/EmbeddingCoordinator.swift`: stale-version loop exists, but no production construction/run call was found. Uses DJ rows, lacks durable window checkpoints, and hardcodes charging/battery in progress words. Replace its scheduling policy. |
| Search | `Sources/DJ/Semantic/SemanticSearchService.swift`: top-400 selection precedes hard filtering, filter-only queries rejected, no selected-source scope, scanner cancellation always false. |
| Vector cache | `Sources/DJ/Semantic/VectorStore.swift`: DB embeddings plus regenerable mmap file; depends on DJ row types and `DatabasePool`. Do not pass a DatabaseQueue where a DatabasePool is required. |
| App wiring | `Sources/DJ/Features/VibeSearch/VibeSearchModel.swift`: assembly makes text encoder/search only. `Sources/Features/Ingest/AnalysisModel.swift`: pause changes display without reliably stopping work. Replace these lifecycle assumptions. |
| Shared algorithms | `Sources/DJ/Semantic/SemanticReexports.swift` reexports `ParsoAudioNeural`; CLAP/preprocess/pooling/quantization/ranking moved there. `Package.swift` pins parso-audio-engine 1.0.0. Preserve reusable algorithms and pin unless a demonstrated build/API defect requires a documented fix. |
| Resources | `Resources/CLAP/`, `Config/models.lock`, `scripts/fetch-models.sh`, generated `Config/models-odr.yml`, `project.yml`, `tools/clap-coreml/README.md`. Weights and generated overlay are absent in this checkout; fetching/generating them is part of build preparation. |
| Existing tests | EmbeddingCoordinatorTests, VectorStoreTierATests, RankingTests, SemanticSearchServiceTests, SearchModelTests, RecallGateTests. Port useful behavior tests; synthetic recall is not musical relevance evidence. |

## 3. Final architecture and file ownership

Use the existing `LibraryStore.dbQueue` as the single database writer. Keep its public compatibility for current callers. Introduce repository interfaces accepting `any DatabaseWriter` (GRDB 7) or concrete DatabaseQueue, rather than opening another database or globally replacing the core queue with a pool. All repositories receive the SAME writer instance. Keep transactions short; no file/network/model work in database closures. A vector binary cache is allowed; it is not a second music database.

Create core schema/record/queue persistence in TonearmCore without adding a TonearmCore → TonearmDJ dependency. Put neural execution and retrieval in a new `TonearmDiscovery` Swift package target depending on TonearmCore, GRDB, ParsoAudioNeural and ParsoAudioAnalysis as needed. Port retained algorithms/services from TonearmDJ into that target, fixing dependencies and tests. App UI and iOS background lifecycle adapters depend on TonearmDiscovery. Keep BackgroundTasks/UIKit behind platform fences and out of portable persistence tests. There must be no cyclic target dependency.

Suggested concrete ownership (equivalent small file splits are fine):

- `Sources/Data/DiscoveryRecords.swift`, `DiscoveryMigrations.swift`: core persistence types and appended migration registration.
- `Sources/Data/IndexJobRepository.swift`, `ImportJobRepository.swift`: transactions, leases, counts, change journal and recovery.
- `Sources/Discovery/DiscoveryAssembly.swift`: one application-owned service graph, initialized without a visible view; no per-screen worker/model instances.
- `Sources/Discovery/IndexScheduler.swift`, `IndexPolicy.swift`, `IndexWorker.swift`: scheduler, deterministic policy, bounded processing.
- `Sources/Discovery/AnalysisAssetResolver.swift`, `WindowedAudioReader.swift`: core assets/cache leases and bounded PCM reads.
- `Sources/Discovery/ModelManager.swift`: shared model resource leases, lazy encoders and execution-context compute configuration.
- `Sources/Discovery/VectorIndex.swift`, `SearchRepository.swift`, `SearchService.swift`: unified-catalog retrieval.
- `Sources/App/DiscoveryBackgroundController.swift`: registration and lifecycle callbacks.
- `Sources/Features/Discovery/IndexStatusModel.swift`, `IndexStatusView.swift`: observable persisted progress.

No runtime access to `DJDatabase`, DJLibraryStore or a DJ `.sqlite` path at completion. Delete the factories, static singletons, migrations and tests that exist **solely to stand up the separate DJ database**. Do NOT delete DJ tab / mixer / deck / workspace UI, routes or view models — re-point them at the core `LibraryStore` writer and the discovery side tables. Port preparation/auto-playlist queries that remain reachable; they must join core track/asset and discovery side tables. A type name or package still containing DJ is not itself a failure; a second catalog/database is. Remove PlaylistCrateImporter's copying behavior: core playlist track IDs are already the IDs to use.

## 4. Unified schema and identity

Append the next unused core migration (v18 at writing); preserve historical core migrations and all source/track/asset/playlist/sync data. Register new SQL in the existing Schema migrator. Disable erase-on-schema-change except in explicit disposable test fixtures.

All derived rows reference core `track.id`, and asset-dependent rows also record `asset.id` and a monotonic content revision. All new tables are device-local: exclude jobs, caches, derived analysis, model state and checkpoints from CloudKit export. Incoming core sync mutations must still enqueue local work. Use foreign keys with cascade deletion and CHECK/UNIQUE constraints for state and identity invariants.

| Table | Required fields/invariants |
|---|---|
| `discovery_asset_state` | assetId PK/FK, contentRevision >=1, observed size/mtime/provider validator nullable, canonical revision signature, lastValidatedAt. Cache path/last-access changes alone are NOT content revisions. |
| `discovery_track_analysis` | trackId PK/FK, assetId, assetRevision, analysisVersion, nullable BPM/key/energy/phrase summary, completion time. Unknown values stay NULL. Preserve canonical track metadata separately. |
| `discovery_embedding` | trackId PK/FK, assetId, assetRevision, modelVersion, preprocessingVersion, samplingVersion, dimensions, quantized vector blob, scale, completedAt. Validate length, finite numbers and nonzero norm. |
| `discovery_index_job` | UUID PK, trackId FK, selected assetId nullable, assetRevision nullable until selected, pipelineVersion, state, priority, createdAt, updatedAt, nextAttemptAt, attemptCount, leaseToken nullable, leaseExpiresAt nullable, completedWindows, totalWindows, embeddingStageState, musicalAnalysisStageState, errorCode/message nullable. One active logical job per track and pipeline version; replace/restart it on revision changes. |
| `discovery_window_checkpoint` | jobId FK, revision/version signature, windowIndex, startSeconds, embedding blob, pooling weight, completedAt; unique(jobId, windowIndex). This is durable intermediate work, not searchable partial-track output. |
| `discovery_change` | monotonically increasing id, trackId nullable, kind, createdAt; durable transactional outbox for catalog/revision/delete invalidation. |
| `discovery_setting` | key/value for global pause, indexing consent/model download consent, charging-only preference, per-source acquisition preference and schema-versioned settings. |
| `discovery_import_job` | UUID, sourceId nullable FK, source kind, resumable locator/bookmark reference, state, persisted provider cursor/checkpoint, discovered/imported/failed counts, enumerationComplete, last error, timestamps. Never store credentials in diagnostic fields. |
| `discovery_import_item` | jobId FK, stable provider/local item identity, state, resulting core trackId nullable, error; unique(jobId, identity), so replay cannot duplicate tracks. |
| `discovery_runtime` | singleton: last run/start/stop reason, background submission result/time, last successful work time; telemetry, not the authoritative queue. |

Use states: `queued`, `running`, `waitingForModel`, `waitingForAsset`, `waitingForNetwork`, `waitingForPower`, `waitingForCooling`, `retryScheduled`, `failed`, `complete`, `unsupported`. Global user pause is a persisted scheduling gate, not thousands of per-track mutations. Stage states are pending/running/complete/failed/unsupported; embedding coverage counts only a valid final embedding, independently of optional musical-stage failure. A job is complete when both stages are terminal; terminal failures remain separately counted and retryable. Store machine-readable reason codes; UI supplies text. Never count failed/waiting jobs as completed.

Maintain a catalog generation counter or change sequence for query/cache invalidation. Insert compact outbox changes transactionally alongside core inserts, deletes and relevant asset changes. SQL triggers are the backstop for writes outside LibraryStore, including sync/importers; keep trigger logic small and let a reconciler select assets and create jobs. Do not make every metadata edit re-embed audio. Core title/artist edits invalidate search presentation; content replacement invalidates analysis/embeddings/checkpoints. Readiness events retry waiting jobs without falsely incrementing content revision.

At launch and after outbox changes, reconcile in bounded pages (200 tracks). Bootstrap ALL existing core tracks, not just future imports. Use indexed keyset pagination, not a full catalog materialization on the UI thread. Deletion must remove derived DB rows and invalidate vector snapshots even if an active worker finishes afterward. Every final write checks track/asset existence, revision and lease token in the same transaction; stale results are discarded.

## 5. Imports, assets and durable acquisition

Trace `ImportRouter`, AppState import methods, folder scanning, remote provider sync, share-extension handoff, LibraryStore insert/update methods and AudioCache completion. All committed core tracks become discoverable by the outbox/reconciler. No indexing in an import callback, database trigger or UI task. Wake the scheduler only after commit.

Persist import job state BEFORE enumeration. Commit each bounded batch and its cursor/item checkpoints together. If a provider has no resumable cursor, replay its enumeration with idempotent item identities. A Files picker security scope must become a durable bookmark or app-owned staged copy before its callback ends. Interrupted jobs return to queued/retryable on launch. Import cancellation stops enumeration at a checkpoint; already imported tracks remain. Represent unknown total as “127 imported · discovering more,” never a fabricated percent.

Resolve playable, complete local assets first: app-owned files, valid security-scoped bookmarks, then complete AudioCache entries. Hold the security scope/cache pin from before read until checkpoint/result completion. Partial range caches are not valid complete audio. Provider authorization errors become actionable waiting states, not silent skips or credential dumps.

Select one deterministic preferred analyzable asset per track (valid local original, then complete cache, then explicitly authorized downloadable original; tie by asset ID). Persist the selection for the job. Source replacement changes the revision even if the title is identical. Compare observed size/mtime/validator before and after processing; invalidate if changed. Hashing, when needed for ambiguous replacement detection, is streaming and off-main. No hash-based merging of unrelated core tracks.

Default automatic indexing covers locally readable owned music. Remote bytes use existing provider/download/cache APIs, one acquisition at a time, honoring cellular settings and provider rights. Add per-source “Download music for indexing” opt-in, off by default, with a 1 GiB maximum temporary acquisition budget and 1 GiB free-disk reserve. Use background URLSession downloads only for providers supported by that mechanism; others checkpoint and resume while the app has execution time. Unsupported background acquisition is not unsupported foreground indexing. Do not add a new streaming extraction mechanism. Excluded/unavailable tracks stay visible with a reason; “everything indexed” means all eligible tracks, not every inaccessible remote entry.

## 6. Execution, windowing and thermal policy

An async function or `Task {}` created inside a MainActor method does NOT prove heavy work is off-main. Put synchronous decoder/preprocessor/inference wrappers on a dedicated serial utility DispatchQueue, bridged with checked continuations and Sendable inputs/outputs, or an explicit dedicated serial executor. No `DispatchQueue.main.sync`, synchronous waits from UI, or MainActor worker methods. Use actors for scheduler/model/index ownership, not as a substitute for auditing where synchronous work executes. Add debug assertions at heavy-work entry points that `Thread.isMainThread == false`; instrument queue labels/signposts.

Only ONE analysis job executes at a time across BPM/key analysis and CLAP. Do not retain the old performanceCoreCount−1 parallel analysis policy. Search has priority over starting the next audio window. Serialize shared model access; an in-flight Core ML prediction may finish before cancellation takes effect. Cancellation is checked before/after each window, decode block, DB commit, and vector scan block. Propagate a real thread-safe cancellation token to synchronous scanner callbacks. Do not use unstructured tasks without an owner and cancellation path.

Replace whole-file decode/all-windows allocation with a bounded reader. Use AVAudioFile/AVAudioConverter or the existing streaming decode substrate behind an interface that yields bounded mono 48 kHz PCM. For codecs needing the existing decoder, implement bounded streaming through that substrate; never silently fall back to unbounded whole-file PCM. Corrupt/unsupported files produce explicit terminal states. Maintain one 10-second PCM window and its frontend tensors at a time; release temporaries inside autorelease pools where appropriate.

Fixed v1 sampling policy (version it): for tracks <=10 seconds, one zero-padded window; otherwise at most 12 windows, evenly distributed from 0 to duration−10 seconds inclusive. Count = min(12, ceil(duration/10)). Process positions in ascending order. Determine duration from actual readable media when metadata is absent. This sampled whole-track representation is intentional for phone resource use; do not claim every second was analyzed. Persist each completed window vector immediately. Resume at the next missing window after relaunch. Use the shared configured pooling algorithm and its required weights over the bounded completed set; quantize only the final normalized pooled vector. Version the sampling change so old incompatible vectors cannot be queried together.

Musical BPM/key/energy analysis is a separate checkpointed stage under the same job/scheduler. Reuse the shared analyzers over a bounded sample (up to 60 seconds from the track midpoint, shorter files in full); store analysis scope/version and unknown values where confidence/availability is inadequate. Do not present sampled phrase/grid analysis as a full-track beat grid. Missing analysis must not block semantic retrieval; embedding completion and musical-analysis coverage are separately observable. Existing full-grid preparation consumers must use their explicit analysis path, not infer full grids from these summaries.

Initial policy constants, implemented with an injected clock/power/thermal snapshot for tests:

| Condition | Action |
|---|---|
| User paused | Persist pause; finish/checkpoint current bounded operation, start nothing else. Resume requires explicit user action. |
| Foreground, nominal thermal, battery >=30%, Low Power Mode off | Allow one worker; wait 2 seconds between audio windows. |
| Foreground, charging-only setting on and unplugged | Wait for power. Charging-only default OFF; expose it clearly. |
| Low Power Mode, battery <30% or unknown while unplugged | Pause automatic indexing. A user may request one selected track in foreground; never override serious/critical thermal gates. |
| Thermal fair | Stop automatic indexing after current window; wait until nominal continuously for 60 seconds. |
| Thermal serious/critical or memory warning | Checkpoint/cancel, release models and buffers when safe; wait for recovery. |
| Playback active | Pause automatic audio analysis to prioritize listening; search remains available. Resume when playback stops. |
| Background | Only run under a granted processing task, charging required; otherwise checkpoint and suspend. |

These are conservative policy defaults, not a promise to prevent all device warmth. Do not use fake battery values. Enable real battery monitoring in the iOS adapter. Observe power, thermal, playback and memory events. Use cancellable timers/event wakes, not polling loops. Priority is selected-track request, newly imported tracks, then oldest backlog, with age promotion so continuous imports cannot starve older music. Limit foreground runs to 2 minutes before a 30-second cooldown; persist work and show the reason. A timer must not keep the app alive illegally in background.

## 7. iOS background/restart contract

Use iOS 18-compatible BackgroundTasks. Register `guru.parso.tonearm.discovery-index` once during application launch, before completion, using an app-owned delegate/controller reachable in headless launch. Add the identifier to BGTaskSchedulerPermittedIdentifiers and `processing` to UIBackgroundModes in the generated app configuration; preserve existing legitimate audio modes. Do not use silent playback to keep indexing alive.

Submit a BGProcessingTaskRequest when pending local work exists and on background transition. Set requiresExternalPower=true and requiresNetworkConnectivity=false for the local indexing task; acquisition is separate. Set earliestBeginDate to now+15 minutes and respect retry dates. Coalesce pending requests for this identifier; do not cancel unrelated app tasks. Record submission errors without losing jobs. Register an expiration handler immediately; it cancels the shared worker, leaves durable checkpoints, and completes the BG task exactly once. Resubmit pending work after each grant. Treat system execution as opportunistic; earliestBeginDate is not an appointment.

On scene background without a processing grant, stop starting windows, request a short UIApplication background assertion only to finish/checkpoint the current bounded operation, then end it. If expiry prevents a commit, replay that window later. Do not assume the foreground GPU inference can legally continue in background. Configure background CLAP execution for `.cpuOnly`; foreground may use the known working CPU/GPU configuration. Recreate/lazily reload encoders when execution context changes; never reuse a GPU-configured instance for background work. If CPU-only loading/prediction fails, mark runtime background inference unavailable with a recoverable reason, preserve the queue, and continue indexing in foreground; report this limitation rather than spinning or claiming success.

At process launch, reset stale running leases from the prior process to queued; only one scheduler exists per process. Claim each job transactionally with a unique lease token; completion requires that token. Background and foreground callbacks share the same scheduler, preventing duplicate workers. Recover after expiration, process death and device reboot. A force-quit may prevent background relaunch until the user opens the app; opening always resumes eligible work. UI copy: “Progress is saved. Indexing resumes when you open the app or iOS allows background processing.” Never promise continuous execution or a completion time while suspended.

Apple references already checked for this design: [Background Tasks](https://developer.apple.com/documentation/backgroundtasks), [requiresExternalPower](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresexternalpower), [earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [BGProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask). These establish registration, power constraints, earliest-time semantics and expiration handling; policy constants above are our choices.

## 8. Model delivery and index consistency

Use the pinned CLAP audio/text resources from Config/models.lock and existing conversion tooling. Run `make models` and `make project` on the build host. Do not substitute fake embeddings when resources are missing. Keep stem-resource cleanup consistent with removed consumers, not a prerequisite for implementing search.

ModelManager owns one shared ModelResourceService and balanced resource leases. Resolve actual resource URLs AFTER successful acquisition, then initialize encoders. Recognize compiled `.mlmodelc` when supplied by the build as well as `.mlpackage` when runtime compilation is necessary; no guessed pre-download path captured forever. Validate encoder input/output names, dimensions and tokenizer/frontend resources using the shared implementation. Run real-resource loading smoke tests on the Apple build host. Fetch failure must carry a retryable error; missing model, failed download and failed inference are distinct states. Avoid duplicate concurrent ODR requests. Recheck availability on reacquisition and recover from eviction.

Keep embedding rows authoritative; put vector cache files under a new core discovery Caches directory. Do not trust an old DJ vectors.i8 file. Implement index ownership as a single actor with serialized mutation/publication. Build immutable, generation-stamped vector snapshots off-main and atomically publish them for scans. For large rebuilds use temporary files/atomic rename and validate expected byte length/version/dimensions. A missing, truncated or purged cache triggers rebuild from core embedding rows. Never mark jobs incomplete merely because this disposable cache disappeared.

Avoid filesystem append inside the canonical embedding transaction. Commit final embedding + job completion + change generation atomically, then update/rebuild the derived cache. If killed between commit and cache publication, reconcile generation and rebuild before using stale snapshots. Searches use a consistent snapshot and eligible-ID set at a recorded generation, then validate live IDs/revisions before materialization. Retry once if invalidation materially changes the result; otherwise return a stated refreshing state. Bound retained old snapshots and release them when queries finish.

## 9. Retrieval contract and scoring

Use core `TrackRow` (or a discovery DTO carrying its ID/syncID) as results. No DJTrackRow joins. Search, similar-track search, saved searches and auto-playlist candidate retrieval share the same scope/filter semantics and repository. No duplicate independent scoring implementation.

Query is a Codable validated value: text, positiveTerms, negativeTerms, optional sourceIDs/playlistID, optional BPM range, compatible key, limit (1...200, default 50). A selected scope is explicit; deleted scopes return unavailable/empty scope rather than silently widening to all music. Normalize whitespace and reject nonfinite/reversed BPM constraints, excessive text/refinement sizes and invalid key codes with an actionable validation result. Limit text input to 500 characters and 8 refinement terms of 100 characters each; tokenizer still enforces its actual model token limit and UI discloses truncation if it occurs.

Modes:

- Text/semantic: encode text/refinements and compare to current compatible audio embeddings.
- Similar: use current reference embedding, exclude only that reference track ID, apply scope/filters; no text model required. Missing/stale reference embedding offers Analyze this track.
- Filter-only: apply scope/BPM/key directly in SQL, WITHOUT requiring CLAP models or embeddings. Stable sort by core sortKey then track ID. Do not fabricate a semantic score.
- Empty text with no musical filters: show ordinary scoped library browse/metadata search behavior, not an error. Existing metadata search remains usable without model download. Label metadata and semantic result modes distinctly.

Apply scope, current revision/version eligibility and hard BPM/key constraints BEFORE top-K truncation. Implement an exact chunked scan over ALL eligible vectors, maintaining a bounded top-K heap; use an eligible-ID mask/filter during scanning. If the shared scanner cannot accept this, implement a small app-side streaming scanner using shared vector decode/dot/ranking helpers. Do not add an ANN dependency, copy the entire matrix per query, or solve starvation by changing 400 to another arbitrary cap. Rank final hybrid scores during that eligible scan so a fixed semantic shortlist cannot hide a better hybrid result. Keep SQL IN queries chunked below the database parameter limit or use a temporary eligibility table/query; test 20,000 IDs.

Scoring policy: reuse HybridRanker and RankBreakdown. Default component weights remain semantic .40, BPM .20, key .20, energy .10, phrase .10. A plain text query has no musical target, so neutral musical terms are constants and semantic similarity determines ordering. Similar-track queries may use valid reference attributes. Do not invent an energy/phrase target from prose. Hard musical filters exclude unknown required attributes; no-filter semantic search includes tracks missing BPM/key. Tie-break finalScore descending, semantic similarity descending, core track ID ascending. Pin this in tests. Audit signed cosine handling in the shared ranker; raw cosine is −1...1, not a probability. Expose the raw score only as similarity, never “87% confident.” Preserve documented ranker transforms in one place.

Positive/negative refinements are soft vector nudges. They do NOT guarantee “no vocals,” “not explicit,” or any semantic exclusion. UI must label them “More like / Less like.” Structured BPM/key/source filters alone are hard gates. Do not add an explicit-content guarantee without canonical reliable metadata.

Propagate cancellation through text inference scheduling, database pagination and scan blocks (<=256 vectors between checks). Debounce text input 250 ms and retain the generation guard for stale responses. A cancelled search must not update results/errors or retain obsolete snapshots. A running prediction may complete, but its result is discarded and no further work starts for that cancelled query.

Coverage derives from the selected catalog scope BEFORE musical filters: total tracks, currently indexed, eligible awaiting indexing, waiting for assets, failed/unsupported. Separately show count matching hard filters. A fresh empty library, empty scope, zero indexed tracks, indexing in progress, model missing, model download failed, no matches and source unavailable are distinct response states. SQL errors are errors, not `(0,0)` coverage. Index changes, imports, source deletes and asset replacement invalidate counts and query results. Observe DB changes with throttled refresh; do not rescan on every progress tick.

## 10. UI acceptance specification

Reuse existing native list/search patterns; no HTML mockup is needed for this bounded addition. Make the following reachable from the ordinary Library screen and not requiring the DJ tab or any paywall (the DJ tab still exists and may also surface search):

1. Search entry with metadata/Find by sound mode, source scope picker, editable BPM/key filters and More like/Less like refinements. Result row: title, artist, source, optional musical metadata, Play, More like this; score details show actual available components.
2. Persistent compact status banner: “Sound index: 238 / 1,042 tracks” and actual state such as “Waiting for charging.” Tap opens full status. Import status is separate: “Importing: 127 tracks · discovering more.”
3. Full status screen with Imports and Sound indexing sections, per-source counts, current track/window progress, queued/completed/waiting/failed lists, last activity time, model download state and background scheduling reason. Large lists paginate. Counts reload correctly after relaunch.
4. Actions: Pause/Resume (real scheduler control), Retry failed, Analyze selected next, download models, charging-only toggle, per-source acquisition opt-in, open source/relink inaccessible file. Retry does not reset completed tracks. No “finish in 10 minutes” while iOS/power gates prevent work.
5. Accessibility labels, Dynamic Type and VoiceOver status; avoid announcing every window. Publish UI snapshots at most twice per second. No model/database work in body, onAppear or MainActor computed properties.
6. Export diagnostics as redacted JSON through the share sheet: app/build, OS/device family, model/pipeline versions, aggregate counts, pause/background reasons, durations and recent coded errors. Exclude track names by default, URLs, bookmarks, tokens and audio. This supports the owner's later TestFlight report.

## 11. Implementation sequence and required automated checks

Create `docs/plans/clap/IMPLEMENTATION_STATUS.md` with C01–C09, changes, exact checks/results and unresolved blockers. Complete all steps; do not treat the plan or mocks as delivered functionality.

### C01 — Canonical schema and target boundaries

Add discovery persistence to core, introduce TonearmDiscovery, preserve the existing core DB writer. Add schema upgrade fixtures from v17 containing sources/tracks/assets/playlists/syncIDs and assert exact preservation. Assert foreign keys/cascades, uniqueness, no app schema erasure and derived tables excluded from sync. Start moving shared discovery code, keeping each commit buildable.

### C02 — Retire separate catalog and port consumers

Port search/analysis repositories and reachable playlist/preparation consumers to core IDs. Remove the separate DJ *database* assembly and its duplicate import path only. The DJ tab, mixer, decks and workspace are NOT removed — rewire them onto the core `LibraryStore` writer and discovery tables so they keep working against the unified database. Audit every DJLibraryStore/DJDatabase reference across app, extensions, packages and tests and repoint (not delete) the ones that back live DJ UI. Add an integration test proving import, playback selection, search and playlist items share the same track ID and writer. Assert app bootstrap does not create/open the old DB. Old DJ-only data (cues, beatgrids, crates, mix history) is intentionally not migrated.

### C03 — Durable import/outbox/queue

Wire all import/sync/cache paths through transactional outbox reconciliation and persistent import status. Implement jobs, leases, recovery, prioritization, retry (30 s, 2 min, 10 min, 1 h; max 5 transient failures then manual retry), waiting reasons and revisions. Waiting on model/power/network does NOT consume retry attempts. Test kill/recreate scheduler mid-import, replay/idempotence, post-commit wake, source deletion, replacement during work, competing launch callbacks, corrupt audio and checkpoint rollback.

### C04 — Assets, models and bounded worker

Implement security-scope/cache lifetime, acquisition limits, resource acquisition, lazy model URLs, bounded audio windows and resume. Replace whole-file CLAP execution and parallel analysis lanes. Test short/long/silent/corrupt fixtures, deterministic sample positions/pooling, finite vectors, cancellation, revision mismatch, resource eviction and balanced leases. Use synthetic test encoders for deterministic automation but also run real model load/output-shape smoke checks on an Apple host. Assert main-thread guards and maximum one inference/analysis worker. Verify buffer/window bounds with a long generated fixture, not only a 10-second file.

### C05 — Scheduling, background and status persistence

Implement policy, iOS registration/processing handler, foreground transitions, cooldown and diagnostics. Use injectable BackgroundTaskScheduling and power/clock interfaces to test registration, request coalescing, expiration during window/commit, completion exactly once, relaunch recovery, fair/serious thermal, LPM, battery threshold, playback gating, user pause persistence and age-based fairness. Do not require iOS to grant a real task to pass deterministic tests. Ensure headless initialization never depends on RootView appearing.

### C06 — Unified retrieval and vector recovery

Implement eligible exact hybrid scans, filter-only mode, scope, cancellation and truthful states. Mandatory fixtures: valid filtered match ranked below the old global top 400; hybrid winner below a semantic-only shortlist; out-of-scope nearest matches; unindexed filtered results; empty index vs no matches; 20,000-track scope without SQL-variable errors; signed cosine; deterministic ties; stale query/index generation; source deletion; reference exclusion; mixed versions; missing/truncated cache rebuild; commit-before-cache crash. Port saved queries and auto-playlist candidate retrieval to the same contract.

### C07 — Native integration

Wire all UI in section 10 to real services. Exercise normal import → observed queue → index → search → play → saved query from the ordinary Library screen without requiring the DJ tab (the DJ tab remains present). Tests cover resume state from disk, actual pause, source scope switching, model errors, filter-only operation with no models, stale response suppression and accessible controls. Do not add a new paywall.

### C08 — Build and developer verification

Run repository guards and appropriate targeted tests during implementation, then the required hook-backed `make test-local` on an Apple build host; use `make models`/`make project` and project generation when resources/targets change. Run a simulator UI smoke flow, a real-model inference smoke test on Apple hardware and Instruments Main Thread Checker/Time Profiler where available to establish heavy work runs off-main. These are implementation checks, NOT human judgments of musical relevance. Keep UI regression suites out of CI/hooks per CLAUDE.md. If this agent runs on Linux without Swift/Xcode, finish all reviewable work but report Apple build/testing as outstanding; never mark C08 complete from source inspection.

Search remaining app runtime references and prove no second music DB opens. Update root preparation recommendations to point to this plan for unified identity and CLAP; remove conflicting bridge/migration directives. Add README/status documentation describing actual behavior and platform scheduling limits. No TODO/stub or fake production inference in a completed step.

### C09 — Commit, TestFlight handoff, human checklist

Commit with required hooks. Ask before push only if not already authorized, identifying the repository rule. After authorized push, verify the project's existing CI/archive/TestFlight path and record commit, build number, upload status and any failure. A pushed commit alone does not establish TestFlight availability. Fix build/upload failures within available credentials/access; report external blockers accurately. Do not request human relevance testing until the build is available in TestFlight. Automated implementation tests remain required before delivery.

## 12. Owner checklist — AFTER TestFlight availability

Copy this section into `docs/plans/clap/TESTFLIGHT_HUMAN_CHECKLIST.md` as part of C09. Leave results blank; the coding agent must not invent human scores. The owner does not need to do this before code completion/push/upload.

Record build/device/OS, approximate library size, model download status and initial indexed count. Use DRM-free music you own, starting with 50–100 varied familiar tracks; then use your real collection. Musical quality assessment is separate from whether iOS happens to grant background time.

1. Import a folder. Confirm tracks immediately appear in the ordinary library and importing/indexing show separate real progress. Scroll and play music during import; report any freezes or audio interruptions.
2. Allow model download and indexing. Confirm completed count rises, pending falls and no second library/import is required. Open several results and verify they play the same imported tracks.
3. Pause, close and reopen. Pause must persist. Resume, leave the app, later reopen: previously completed work remains and remaining work resumes. Try one force-quit; do not expect iOS to run it while force-quit, but progress must survive reopening.
4. Leave the phone charging with the app backgrounded overnight. Record count before/after and displayed scheduling reason. No progress alone does not prove a defect because scheduling is discretionary; include diagnostics. Check that device warmth and battery behavior are acceptable during foreground indexing.
5. Try 10–15 short sound descriptions appropriate to YOUR collection, e.g. “gentle acoustic guitar,” “fast distorted guitars,” “slow atmospheric electronic,” “bright danceable synths,” and “sparse piano.” Before each search, note 1–3 tracks you expect if you know them. Judge the top 10 as good/plausible/wrong and whether an expected track appears. Do not expect every example to match a collection lacking that sound.
6. Select 5 familiar reference tracks and use More like this. Judge the top 10 for useful sonic similarity. Reference itself should be absent; same-artist tracks are allowed. Note whether results are useful beyond title/artist matching.
7. Repeat searches scoped to one source and with BPM/key filters. Check every shown result obeys hard filters; missing musical metadata must not be guessed. Clear text but keep filters: it should still work without a text model.
8. Try More like/Less like refinements. Judge whether they help, understanding they are soft preferences, not guaranteed exclusions of vocals or other content.
9. Import additional tracks, replace one audio file, remove a source, and reopen the app. Confirm new work appears, replaced audio reindexes and deleted tracks disappear from results. Missing remote/local files should show a reason and recover when access returns.
10. Repeat a few queries while indexing is ongoing and after it completes. Record latency perceived as instant/acceptable/slow, relevance changes and any stale-scope results. Export redacted diagnostics for failures.

Suggested decision rubric (owner evaluation only): no data loss/UI freezes/hard-filter violations; useful results in at least 7 of 10 representative text queries and 4 of 5 similarity queries. These are product targets, not claimed current results. If mechanics pass but relevance disappoints, report examples and versions for a later scoring/model iteration; do not retroactively label synthetic recall as relevance validation.

## 13. Completion checklist

- [ ] Core library.sqlite is the only runtime music catalog; no DJ ID bridge or old DB access.
- [ ] DJ tab, mixer, decks and workspace still present and functional, running on the core database.
- [ ] Core user data preserved; abandoned DJ-only data (cues, beatgrids, crates, mix history) is not migrated.
- [ ] Existing and new core tracks enter durable, version-aware indexing.
- [ ] Imports and indexing have separate persistent status and recovery.
- [ ] Heavy work off-main, bounded memory, one worker, policy gates and real pause.
- [ ] Background grants/expiration/restart preserve progress; UI states platform limits accurately.
- [ ] Model download/load/retry and derived vector-cache recovery work.
- [ ] Search, similar, saved searches and generation use unified IDs and consistent filters.
- [ ] Candidate starvation, filter-only mode, selected coverage and cancellation fixed.
- [ ] Automated checks and Apple-host validation recorded accurately.
- [ ] Commit/push/TestFlight state recorded without bypassing repository approval/hooks.
- [ ] Owner checklist delivered for evaluation after TestFlight; no human relevance gate blocks coding.
