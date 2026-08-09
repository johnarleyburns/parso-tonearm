# Platterhead iOS DJ — agentic implementation handoff

You are picking up work in `/Users/arley/github/parso-tonearm`. **This file is the operating
brief.** Read it fully before touching anything. `CLAUDE.md` at the repo root loads automatically
and carries two rules this file does not repeat — the **Swift 6 hard rule** (full strict
concurrency, no warning suppression, no escape hatches) and the **git-hook timeouts** below.
Read it too; it is short.

The design is already written and is not yours to re-litigate:

- **[`PLATTERHEAD_IOS_ARCHITECTURE.md`](PLATTERHEAD_IOS_ARCHITECTURE.md)** — 7,000-line
  implementation-ready spec. §49 is the execution guide, **Appendix M is the per-milestone file
  manifest**, Appendix L is requirement→test traceability.
- **[`mockups/index.html`](mockups/index.html)** — every screen, 31 files. Build views against
  these, not against taste.
- **[`../tonearm-mvp/DJ_PLATFORM_STRATEGY.md`](../tonearm-mvp/DJ_PLATFORM_STRATEGY.md)** —
  pricing and packaging. **Authoritative** wherever it and the spec disagree.

**This handoff carries only what the spec cannot know**: how this repo actually operates, and
the places where the spec's invented details conflict with repo reality. Where they conflict,
**repo reality wins** — §6 of this file lists the known ones.

---

## The programme in one paragraph

Retarget the shipping Platterhead player into a universal iOS/iPadOS app that is also a two-deck
DJ instrument. The free/Pro line is redrawn from *"reach"* to *"listening vs performing"*: remote
libraries, on-device semantic search and auto-generated playlists become **free**, and a single
one-time purchase unlocks decks, stems, recording and hardware. Seven milestones (M0–M6),
**three of which ship the free tier before the paid feature exists.**

## Your first task: **M0 only**

Do not attempt the whole programme. §8 explains how later milestones are picked up.

---

## 0. Starting a session

### 0.1 Preflight — once, before any agent runs

The plan is only useful if an agent can read it. Commit it on `main` — do not branch (§1).

```bash
git status --short                  # docs/plans/tonearm-mvp-ios/ must not be untracked
git add -A && git commit -m "docs: go-live defect register, twin-deck spec, UI regression harness"
```

`.gitignore` must land in that commit — it is the only committed protection for
`.test-credentials`. Verify with `git check-ignore -v .test-credentials` *before* pushing.

### 0.2 The session model

**One session per PR, not per milestone.** Context degrades across a long session and the working
agreement (§3) already cuts the work into PR-sized pieces. A fresh session per PR reads this file,
reads the two or three spec sections its PR names, and does one thing.

`core.hooksPath` is set to `scripts/git-hooks`, so **every `git commit` runs the full local suite**
— Swift tests *and* simulator UI smoke tests. Allow 5 minutes for a commit and 2 for a push, per
`CLAUDE.md`. An agent that assumes a commit is instant will look hung and get killed mid-hook.

### 0.3 Two independent tracks

M0 splits cleanly in two, and the split is worth using:

| Track | PRs | Touches | Ships |
|---|---|---|---|
| **A — go-live defects** | 0.6–0.11 (Part X) | `Sources/Features/NowPlaying`, `Sources/Features/Playlists`, `Sources/Remote/RemoteConnectorCatalog`, `Sources/Data/LibraryStore`, `UIRegressionTests/` | on its own, immediately |
| **B — DJ foundations** | 0.1–0.5 (Appendix M.1) | `Sources/DJ/**` (new), `Package.swift`, `Sources/Pro/`, `Tests/` | with the same free update |

The file sets are disjoint **except for the generated `Tonearm.xcodeproj/project.pbxproj`**, which
both tracks touch whenever a file is added. Do not merge that file: re-run `xcodegen generate` on
the merged tree and commit the result. That is the only expected conflict.

**Run Track A first if you run them in series.** It is independently shippable, it is the go-live
gate (§48.1), and it touches code users see today. Track B is invisible scaffolding until M1.

### 0.4 Kickoff prompts

Paste one of these into a fresh session. Each is deliberately narrow.

**Track A — first PR (the archive.org catalog fix, D-9):**

> Read `docs/plans/tonearm-mvp-ios/HANDOFF.md` in full, then `CLAUDE.md`, then spec Part X §51.4
> and §53 of `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`.
>
> Implement **PR 0.6 only**: re-key `RemoteConnectorCatalog` by `connectorID` so a connector can
> serve several `SourceKind`s, fixing D-9. §51.4 has the diagnosis — read it before you read the
> code, then confirm it against the code rather than trusting it.
>
> Commit on `main`; do not branch. Add a test asserting **every** `SourceKind` case resolves to at least one
> connector. Then fill in the `testArchiveOrgPublicCollectionAddsAndPlays` lane in
> `UIRegressionTests/RemoteLibraryRegressionUITests.swift` and make it pass against "The Vapor
> Vault" — the lane going green is what closes the defect (§53.6).
>
> Do not fix any other defect in this PR. Do not wire the regression suite into CI or a hook.
> Ask before pushing.

**Track A — the Now Playing rebuild (D-1…D-6), after 0.6:**

> Read `docs/plans/tonearm-mvp-ios/HANDOFF.md`, then spec §51.2 and §52.
>
> Implement **PR 0.8 only**: rebuild the Now Playing control layout per §52 — six primary
> controls, an overflow menu, shuffle and repeat moved beside the transport, no overlay on the
> artwork, 44 pt minimum targets.
>
> §51.2 says the toolbar's intrinsic width is 420 pt in 345 pt of space, and that the "missing"
> watch and download buttons exist in code and are probably being pushed off-screen. **Verify
> that on the simulator before you change anything** — if they are reachable and still do
> nothing, that is a second defect and you should report it rather than absorb it.
>
> Fill in the `NowPlayingRegressionUITests` lanes as you go. Assert frames and hittability, not
> just existence (§53.5). Commit on `main`; do not branch. Ask before pushing.

**Track B — DJ foundations:**

> Read `docs/plans/tonearm-mvp-ios/HANDOFF.md` in full, then §5 of that file, then spec §48.1 and
> Appendix M.1.
>
> Implement **PR 0.1 only**: the `TonearmDJ` library product and the `CSQLiteVec` C target per
> §9.1, with empty module skeletons. The point is that the build graph exists and **no
> `#if os(...)` guards the DJ target** (§4.6). Mind the SPM/`project.yml` duplication trap in §2.
>
> Run `xcodegen generate` and commit the regenerated project. Commit on `main`; do not branch.
> Ask before pushing.

**Any later milestone (M1–M6):** the protocol is §8 of this file. The prompt is the same shape:
read this file, read `§48.<N>` and `Appendix M.<N+1>`, write the plan doc first, then one PR.

### 0.5 What the agent will hand back to you

Blocking items no agent can do — expect to be asked (§6.5, §54.5):

- Create `guru.parso.tonearm.pro.dj` in App Store Connect; mark the old product unavailable.
- A Plex claim token from `plex.tv/claim`, valid four minutes → `.test-credentials [plex]`.
- OAuth app registrations for Dropbox, Google Drive, OneDrive, pCloud → `[cloud-oauth]`.
- Approve every merge to `main`.

---

## 1. Hard constraints (do not violate)

- **Work directly on `main`. Do not create a branch.** This is a deliberate choice by the repo
  owner: agents have repeatedly opened branches and left them unmerged, so the work went nowhere.
  Commit to `main` as you go, in PR-sized commits (§3) — the discipline lives in the commit
  granularity, not in the branch.
- **Ask before you `git push`.** Pushing `main` is what triggers CI and a TestFlight build, so
  push is the approval gate that branching used to provide. Committing locally needs no
  permission; publishing does. Never push without being asked to.
- **XcodeGen owns the project.** `Tonearm.xcodeproj` is generated from `project.yml` with
  **explicit file lists**, and it is committed. After *any* file add/remove or `project.yml`
  change: `xcodegen generate` and commit the regenerated project, **or CI will not see your
  files.** This is the single most common way to make a green local build fail in CI.
- **CI runs `swift test` only.** No simulator tests in CI — the user finds them unreliable on
  GitHub Actions. Do not add a simulator test job.
- **The UI regression suite stays out of CI, out of hooks, out of `make test-swift`.**
  `make test-ui-regression` (spec §53) is run **by hand** before a release. It needs Docker, a
  simulator, and third-party demo servers, so wiring it into CI or a pre-commit/pre-push hook
  would make every commit depend on someone else's uptime. This is a requirement, not an
  oversight — do not "helpfully" automate it.
- **Never commit `.test-credentials`.** Real values live there (gitignored);
  `.test-credentials.example` carries key names only and is committed. No credential may appear
  in a test file, a compose file, a script, or the spec (§54.2).
- **Keep both CI guard steps** in `.github/workflows/ios.yml`:
  - *StoreKit import boundary* — `import StoreKit` is permitted **only** under `Sources/Pro/`
    and `Sources/Features/Settings/ProPaywallView.swift`. **Do not extend the allowlist**
    (§6.3 tells you how to satisfy it instead).
  - *Codename-leak guard* — user-facing strings and `CFBundleDisplayName` say **Platterhead**.
    `Tonearm` survives only as an internal identifier (`TonearmCore`, `guru.parso.tonearm`,
    `tonearm-dj.sqlite`, target and repo names). Never in UI text.
- **The user has no local device.** On-device testing means: merge to `main` + push → CI builds
  a TestFlight build. So everything must actually compile.
  **Ask before pushing.** Committing on `main` needs no permission; pushing it does.
- **No network calls outside the sanctioned paths.** A PR that appears to need a new network
  host is a design bug — escalate, don't add it (spec NFR-PRIV-1, §49.3).
- **Commit trailer on every commit:** `Co-Authored-By: <your model> <noreply@anthropic.com>`.

## 2. Repo operational facts

| Thing | Value |
|---|---|
| Core package | `TonearmCore` (SPM, `Package.swift` at repo root), iOS 17 / macOS 14 / watchOS 10, GRDB 7 |
| Host tests | `make test-swift` (= `scripts/run-local-test-suite.sh swift`) — this is what CI runs |
| Full local suite | `make test-local` · UI smoke only: `make test-ui` · remote integration: `make test-integration` (docker) |
| Simulator | **exactly one**: iPhone 16, iOS 26.5, UDID `D81580B5-1110-4F0A-9AF4-8EAEAB259AF9`. Target `platform=iOS Simulator,name=iPhone 16` |
| App build | `xcodegen generate` then `xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm -destination 'platform=iOS Simulator,name=iPhone 16'` |
| StoreKit local testing | `Resources/Tonearm.storekit`, already wired via `project.yml` (`storeKitConfiguration:`) |
| Existing plan docs | `docs/plans/*.md` — the convention Appendix M's `docs/plans/dj-phase-N-*.md` follows |

**The SPM/project.yml duplication trap.** When spec §9.1 has you add `Sources/DJ` as the
`TonearmDJ` SPM target path, the app target's `sources:` in `project.yml` **must `exclude:` that
directory**, or every file compiles twice — once in the package, once in the app. This is the same
pattern already used for the `TonearmCore` carve-out; copy it and verify with
`xcodegen generate` that zero DJ files land in the app's build phase.

## 3. Working agreement (spec §49.1, restated because it binds you)

- **One PR per numbered sub-task**, never per milestone. Appendix M gives you the PR breakdown.
- Every PR states which **FR/NFR IDs** it advances and which **acceptance tests** it makes green.
- Pure logic lands with unit tests in the same PR. Shell/IO lands with an integration test or an
  explicit note on why it cannot have one.
- **Order within a milestone:** schema and migrations → pure algorithms with golden tests → façade
  and actor plumbing → view models against a fake façade → views last, against the mockup.
- **Definition of done per PR:** tests green · acceptance IDs named · no new dependency without an
  Appendix Q entry · no new network host · mockup coverage contract (§40.6) still satisfied.

## 4. Non-negotiable invariants (spec §49.3)

1. Nothing allocates, locks, or does I/O in the render callback. The debug assertion shim (§46.3)
   is not optional and does not get disabled to make a test pass.
2. No Swift `Hasher` for identity — SHA-256 via `CacheKeyGenerator` (NFR-DET-2).
3. No feature gated on network, account, or iCloud.
4. No telemetry. The existing CI guard fails the build; do not weaken it.
5. **Nothing in the free-tier registry may be re-gated.** A `FreeTierRegistryTests` failure caused
   by adding a Pro gate is the test working correctly.
6. **No `#if os(...)` around DJ core modules.** Platform conditionals belong in the presentation
   layer and in `Sources/DJ/Session/` (§34A) only. This is what keeps a future Mac build on the
   same purchase — do not "helpfully" add an iOS gate.
7. Analysis output stays deterministic and identical across A- and M-series (NFR-DET-3). No
   fast-math, no reassociation, no nondeterministic parallel reduction ordering.
8. The thermal governor (§43.7) is never bypassed to make a benchmark look better.

---

## 5. TASK: Milestone M0 — foundations, entitlement & the free-tier flip

**Spec:** §48.1 (goals and exit) · **Appendix M.1** (file manifest, PRs 0.1–0.11) · **Appendix T**
(entitlement design, Founders grant, free-tier registry) · **Part X** (the go-live defect register,
PRs 0.6–0.11, blocking).

**Goal in one sentence:** make remote libraries free for everyone and land the entitlement
plumbing for a future DJ purchase — *with no Pro feature behind it yet*.

This milestone ships on its own, immediately, as a free update. It is the largest goodwill-per-line
change in the plan and it is deliberately first.

### 5.0 Before you touch anything

Run `make test-swift` and record the baseline. If it is not green on a clean checkout, stop and
tell the user — do not build on top of a red suite.

### 5.1 The call-site inventory (measured — this is your scope)

`remoteLibraries` / `ProFeature` / `ProEntitlement` / `ProGating` appear **97 times across 15
files**. Nothing outside this list should need to change:

```
Sources/Pro/ProFeature.swift              Sources/App/AppState.swift
Sources/Pro/ProEntitlement.swift          Sources/App/TonearmApp.swift
Sources/Pro/ProGating.swift               Sources/Features/Components.swift
Sources/Pro/ProStore.swift                Sources/Features/Ingest/AddMenuSheet.swift
Sources/Pro/ProPaywallModel.swift         Sources/Remote/RemoteLibraryAccessPolicy.swift
Sources/Pro/AddRemoteLibraryProFlow.swift
Tests/FreeTierRegistryTests.swift         Tests/ProEntitlementTests.swift
Tests/ProGatingPolicyTests.swift          Tests/ProPaywallTests.swift
Tests/FolderWatchTests.swift
```

`Sources/Pro/AddRemoteLibraryProFlow.swift` and `Sources/Remote/RemoteLibraryAccessPolicy.swift`
exist *only* to gate remote libraries. Expect to delete the gate, not rewire it.
`Tests/ProGatingPolicyTests.swift` and `Tests/ProPaywallTests.swift` need **rewriting**, not
repointing — they assert the old product's behaviour.

### 5.2 PR sequence

**PR 0.1 — DJ modules compile with no platform gate.**
Add the `TonearmDJ` library product and the `CSQLiteVec` C target per §9.1. Empty module skeletons
are fine; the point is that the build graph exists and **no `#if os(...)` guards the DJ target**
(invariant 4.6). Exclude `Sources/DJ` from the app target's `project.yml` sources (§2 trap).
Vendor `sqlite-vec.c`. Do *not* bundle any model weights — they are On-Demand Resources (§27.1a).

**PR 0.2 — `dj_v2` schema and migrations.**
Spec §13–17. `DJSchema` migrator mirroring the existing `Schema` conventions (snake_case tables,
camelCase columns), `tonearm-dj.sqlite` in Application Support, `vectors.i8` and all caches under
`Caches/` with `isExcludedFromBackup = true` (§13.1 — this is a correctness requirement, not
housekeeping). Record round-trip tests.

**PR 0.3 — folder import and a bare library list.**
Reuse `BookmarkVault` and `FolderWatchService`. §41.2's screen, minimal.

**PR 0.4 — retire `remoteLibraries`. ⭐ Shippable on its own.**
- Delete the `remoteLibraries` case from `ProFeature` and every call site that gated on it.
  All ten providers become free (FR-LIB-7).
- Rewrite `Tests/FreeTierRegistryTests.swift` per §6.2 below.
- Rewrite `README.md`'s free/Pro section to the §2.4 line: *"Free — everything about listening.
  Pro — everything about performing."* Keep the existing tone and the CI-enforcement claim.
- **Do not delete the product from App Store Connect or the `.storekit` file.** Existing
  purchasers must keep a verifiable transaction — the Founders grant depends on it (§6.1).

**PR 0.5 — `EntitlementStore`, `ProCapability`, Founders grant.**
Appendix T.2–T.4. StoreKit 2 `currentEntitlements`, offline-forever cache with no user identifier
in it, a `Transaction.updates` observer started before the first view appears, and the Founders
grant decision table (T.4) with a test per row (AT-STORE-4). **Ambiguity resolves toward granting.**
No Pro capability is gated yet — the enum exists and `isPro` is observable, nothing more.

**PRs 0.6–0.11 — the go-live defect register (spec Part X). Blocking.**
Seventeen defects in the *shipping player* — Now Playing layout, playlist identity, and the
remote connectors — are an M0 exit gate, not a backlog. The reason is this milestone's own
headline: it ships *"every remote provider is now free for everyone"*, and D-9 (archive.org
returns `-1002` for collections, favourites, items and private lists) and D-10 (Subsonic adds a
library that plays nothing) would put that headline over providers that do not work.

**Appendix M.1 is the authoritative PR sequence** — it lists 0.6 through 0.11, with root causes
already diagnosed in §51. Two are one-line causes with wider fixes, worth reading before you
start: the connector catalog is keyed by `SourceKind` when connectors are 1-to-many with kinds
(§51.4), and folder playlists are matched to their source by **title** rather than by identity
(§51.3).

Fill in each defect's UI regression lane in the same PR that fixes it — "the lane is green" is
what closes the defect (§53.6).

### 5.3 Exit criteria (verbatim from §48.1)

> Remote libraries free in production; entitlement plumbing under test with no Pro feature behind
> it yet; the Part X defect register green, verified by `make test-ui-regression`.

Plus: `make test-swift` green, app builds, `xcodegen generate` committed, both CI guards passing,
`AT-FREE-*` and `AT-STORE-*` green. Then **ask the user** before merging to `main`.

---

## 6. Spec-vs-repo conflicts — resolve these the way stated

The spec was written before its author read every file. These are the known divergences.
**Repo reality wins.** If you find another, follow the same rule and note it in your PR.

### 6.1 Product identifiers — use the real ones

The retired product's real ID is **`guru.parso.tonearm.pro`** (`ProEntitlement.productID:21`,
and `Resources/Tonearm.storekit`, already `familyShareable`, `NonConsumable`, 7.99). The spec's
Appendix T.1 has been corrected to match. **Do not coin a new identifier for the retired
product** — changing it would orphan every existing purchase and silently break the Founders
grant. The new DJ product is `guru.parso.tonearm.pro.dj`.

### 6.2 `FreeTierRegistryTests` — its real shape

Appendix T.5 sketches a `Set<GuardedCapability>`. The actual test is **string-based**:
`ProFeature.allCases.map(\.rawValue)` compared against an expected `Set<String>` (currently
exactly `{"remoteLibraries"}`), plus a second test asserting a free-capability string list is
never a `ProFeature` raw value. Keep that shape. M0 changes it to:

- expected paid set → the new DJ capability (or **empty** through PR 0.4, since nothing is paid
  yet — the honest intermediate state);
- free list **gains** `remoteLibraries` and the ten provider strings, plus `semanticSearch`,
  `smartCrates`, `autoPlaylists`, `analysisStage1`, `analysisStage2`, `analysisReadout`,
  `mixPlayback` (spec Appendix T.5).

The later free-tier entries name capabilities that do not exist yet. That is intentional: the
test is a promise made before the feature ships, and it fails loudly if a later milestone gates
one of them.

### 6.3 The StoreKit boundary constrains the design — satisfy it, don't widen it

CI permits `import StoreKit` only under `Sources/Pro/` and `ProPaywallView.swift`. This agrees
with spec T.3, so resolve it the clean way: **all StoreKit stays in `Sources/Pro/`**
(`EntitlementStore`, `ProStore`, the grant logic). Every DJ paywall view consumes the published
`isPro` and never imports StoreKit. The engine has **no knowledge of entitlement at all** — the
gate is checked at intent boundaries in view models (T.3), which is also what keeps
`PerformanceEngine` testable without StoreKit and makes the GPL build a four-line change (T.6).

### 6.4 Naming

The spec writes `Sources/DJ/...` paths. The repo's existing convention is domain-named folders
directly under `Sources/` (`Audio/`, `Data/`, `Remote/`, `Pro/`, `Sync/`). Either is fine —
**pick one in PR 0.1 and be consistent**; Appendix M's paths are indicative, not normative.

### 6.5 What only the user can do

You cannot do these. Surface them, don't work around them:

- Create the `guru.parso.tonearm.pro.dj` non-consumable in **App Store Connect**, set the price
  (see `DJ_PLATFORM_STRATEGY.md` §5.2 — $39.99, launch at $24.99), and enable Family Sharing.
- Mark `guru.parso.tonearm.pro` as no longer available for purchase (**not** deleted).
- Approve any merge to `main`.

Until the ASC product exists, **develop against `Resources/Tonearm.storekit`** — add the DJ
product there so `AT-STORE-*` runs locally without App Store Connect.

---

## 7. Things that will bite you later (flagged now, not your problem yet)

- **§34A `AVAudioSession` is the highest-risk work in the plan** and is deliberately in the same
  milestone as the engine (M4) so its failures surface early rather than in beta. Do not defer it.
- **`sqlite-vec` must be registered via `sqlite3_auto_extension` *before the first connection
  opens*** (§16.3). Doing it lazily is the most likely way to ship this broken; a debug assertion
  should trip if a connection opens first.
- **Measure Tier A before building Tier B** (§16.1, §50.3). If a brute-force vDSP scan is fast
  enough at 30k tracks on real hardware, the ANN index may be deferrable indefinitely.
- **`AT-THERM-1` is a shipping gate for M4**, not a stretch goal: a 90-minute two-deck session on
  battery at 50% brightness that never reaches `.critical`.
- **Recordings are never auto-evicted** (§43.6). Every other cache has a budget; user content
  does not.

## 8. Continuing past M0

Each milestone is a **fresh session**. The protocol:

1. Read this file, then the spec's **`Appendix M.<N+1>`** for the file manifest and PR sequence,
   and **§48.<N+1>** for the goal and exit criteria.
2. **Write the plan doc first** — Appendix M names it (`docs/plans/dj-phase-N-*.md`). Commit it
   before writing code; that is this repo's convention.
3. Build it, one PR per numbered sub-task.
4. **Stop at every ship gate for user review.** M0, M2 (2.0 free), M3 (2.1 free), M4 (3.0 — Pro
   launch) and M6 (3.1) are releases, not checkpoints.

Milestone order and gates:

| M | Theme | Ships | Gate |
|---|---|---|---|
| **M0** | Foundations, entitlement, free-tier flip | ✅ free update | Remote libraries free in production |
| M1 | Analysis stages 1–2 + thermal governor | — | Golden files, NFR-DET-3 |
| M2 | Semantic search (CLAP ODR, tiered vectors) | ✅ **2.0 free** | FR-SEM-3 (≤120 ms @ 30k) |
| M3 | Auto-playlists (sequencer, arcs) | ✅ **2.1 free** | FR-PLIST-2 (±5%), FR-PLIST-8 (≤3 s) |
| M4 | Engine + `AVAudioSession` + StoreKit | ✅ **3.0 Pro launch** | AT-ENGINE-\*, AT-SESS-\*, **AT-THERM-1** |
| M5 | Stems, recording, gig crates | — | AT-STEM-\*, AT-REC-\* |
| M6 | Hardware, split cue, Watch, polish | ✅ **3.1** | AT-MIDI-\*, AT-WATCH-\* |

## 9. When to stop and ask

- Any merge or push to `main`.
- A spec-vs-repo conflict not listed in §6 that changes an interface or an identifier.
- Anything that would need a new network host, a new dependency, or a weakened CI guard.
- A milestone exit gate you cannot meet — say so with the measurement, don't quietly relax it.
- Discovering that a design assumption in §50.3 is false. Those are listed precisely because
  they might be, and finding out early is the point.
