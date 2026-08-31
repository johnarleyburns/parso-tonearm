# Handoff — Watch Artwork Pipeline, Now Playing Fixes & First-Play Audio Route

**Target:** `parso-tonearm` (Platterhead watch app + phone companion)
**Suggested plan path:** `docs/plans/watch-artwork-and-playback/HANDOFF.md`
**Owner:** J · **Mode:** one commit per task on `main`, ask before `git push`

---

## §0 — How to run this session

Read `CLAUDE.md` and `docs/plans/tonearm-mvp-ios/HANDOFF.md` §0 first; the rules there govern this work. In short:

- **Work on `main`. Do not branch.** One task from §9 per commit.
- **`git push` is the approval gate.** Stop and ask before pushing — push triggers CI + TestFlight.
- **Never `--no-verify`.** The pre-commit hook runs the full local suite (logic + simulator tests). Set the commit timeout to ≥ 300s.
- **CI runs `swift test` only.** Do not wire `make test-ui-regression` into CI or a hook.
- Every task lands compiling, warning-free under Swift 6 strict concurrency, with its tests green.

Work the tasks in §9 top-to-bottom; each is sized for one commit and lists its own acceptance + tests.

---

## §1 — Problem statement

Three related defects, all observed on-device on the watch Now Playing path:

1. **No artwork on the watch.** Art is only ever extracted from the downloaded audio file's embedded `AVAsset` cover metadata (`AVPlayerOutput.loadArtwork`). Internet-Archive-sourced audio frequently carries no embedded cover — or carries an auto-generated waveform/spectrogram that `IACoverPicker` already rejects on the phone — so the watch shows the gradient placeholder even when the phone has a perfectly good cover. There is **no path to deliver separate cover art, and no path for user-assigned custom art, to the watch at all.**

2. **System Now Playing shows `0:00 / -0:00` and a dead scrubber.** `WatchPlayer.updateNowPlayingInfo(track:)` posts `MPMediaItemPropertyPlaybackDuration` synchronously in `handleCommand`, at which point `duration` is still `0` because `AVPlayerOutput.load` hasn't awaited the asset yet. The real duration lands later but is never re-posted (`updateNowPlayingTime` only refreshes elapsed + rate). Compounding it, a **silent asset-load failure is invisible**: `AVPlayerOutput` observes only `.AVPlayerItemFailedToPlayToEndTime` (a mid-playback stall), never `AVPlayerItem.status`, so a file that never reaches `.readyToPlay` yields a dead Play button, `0:00`, and no artwork with zero diagnostics.

3. **First play throws a system "Connect Bluetooth" prompt.** `AVPlayerOutput.activateSession()` calls `AVAudioSession.activate()` with `.longFormAudio`; when there is no eligible route the system route prompt appears over the app's sheet, un-owned and unexplained, and the app is left in a half-started state. (Platform reality below in §6 — this is partly unavoidable but must become a deliberate, app-owned first-run step.)

This handoff delivers a unified artwork pipeline (embedded + separate + custom), fixes the two Now Playing defects, and turns the route prompt into an owned flow.

---

## §2 — Invariants this plan must preserve

These are existing repo invariants; the plan is written to honour them and CI enforces several. Do not weaken any.

- **SHA-256 content addressing, never `Hasher`.** Every stored asset filename is `<sha256>.<ext>` (`WatchFileInstaller.contentAddressedName`). Artwork uses the identical scheme via the same `WatchFileDigest.measure`. Two tracks sharing a cover converge on one file for free.
- **Property-list-safe wire metadata.** File-transfer metadata is `[String: String]` only — IDs, sizes, checksums, intent. No dynamic shapes. `WatchArtworkFileMetadata` mirrors `WatchAudioFileMetadata` exactly.
- **Additive, capability-gated protocol — no version bump.** `WatchProtocolEnvelope.currentProtocolVersion` stays `1`. Negotiation requires an *exact* version match (`WatchCapabilityNegotiation`), and **the watch app updates independently of the phone app**, so a version bump would silently break every mixed-version pair mid-rollout. Instead, add `WatchCapability.artworkAssets`; make every new field `Optional` (Swift's synthesized `Codable` decodes a missing optional as `nil`) and every new metadata key default-safe when absent. An un-updated peer simply doesn't get art.
- **No credential- or URL-bearing data crosses to the watch.** Art is delivered as opaque content-addressed bytes + a content hash. No remote URLs, no source identity (§5.2, §14).
- **SwiftData models never cross an actor boundary.** The watch store hands out `Sendable` value snapshots only (`WatchLibraryValues.swift`). New models follow suit; the new resolver operates on snapshots, not `@Model` instances.
- **Pure decision logic is host-testable and lives outside the AV/session layer.** Precedence and reconciliation logic go in `swift test`-able types with no `AVFoundation`/`WatchConnectivity` import, exactly like `WatchPlayerEngine` and `applyWatchDirectives`.
- **Accessibility contract.** Existing ids (`watch.now.artwork`, `watch.now.chooseRoute`, `watch.now.debugRate`, …) keep their meaning; new affordances get ids and update the contract doc/tests.
- **§2.5 storage reserve** still governs acceptance. Artwork is small but is counted; it can never push the watch under the reserve.

---

## §3 — Current state (grounded references)

What already exists and can be built on:

- `WatchTrackModel` **already declares** `artworkID: String?` and `localThumbnailFilename: String?`; `WatchTrackUpsert` and `WatchTrackSummary` already carry `artworkID`. The slots were anticipated but are unwired — nothing delivers art, and `WatchTrackSnapshot` (the value the player receives) drops both.
- **One file ingress:** `WatchProtocolSessionAdapter.session(_:didReceive:)` → `WatchConnectivityCoordinator.receiveFile(_:metadata:)` (line ~335) → `WatchSyncActor` → `WatchFileInstaller.install(stagedURL:metadata:)`. Every received file is currently assumed to be audio. This is the single seam where audio vs artwork routing is added.
- **Audio installer** `WatchFileInstaller` is the template: validate ext/codec → `WatchFileDigest.measure` → checksum/size gate → content-address → atomic move into `audioDirectory` → commit in one SwiftData transaction (`repository.markAsset`) → sweep staging + superseded file. Artwork gets a structurally identical `WatchArtworkInstaller`.
- **Phone already produces real covers:** `Sources/IA/IACoverPicker.swift` (rejects IA waveform/spectrogram junk) and `Sources/Snapshot/WidgetArtworkStore.swift` (`artworkDirectory()`, thumbnail persistence). The phone can pick/resolve a genuine cover, hash it, and ship it.
- **Phone transfer seam:** `PhoneWatchSessionFileTransfer.transfer(...)` builds `WatchAudioFileMetadata` and calls `transport.transferFile(_:metadata:)`. Add a sibling `transferArtwork(...)`.
- **Playback path is otherwise correct:** `WatchPlayer.play` → `WatchPlayerEngine.command(.play)` → `[.loadItem, .play]` → `applyWatchDirectives` applies them in order. The defects are the two in §1(2), not the transport.
- **watchOS ≥ 11 route behaviour** (confirmed): `.playback` + `.longFormAudio` + audio background mode + `activate()` is the correct setup; when no route exists the system either plays to the built-in speaker (newer hardware) or surfaces its route prompt. `overrideOutputAudioPort(.speaker)` is **not available on watchOS** — do not attempt to force the speaker.

---

## §4 — Design: unified artwork pipeline

### §4.1 Artwork as content-addressed assets

An artwork image is stored on the watch exactly like an audio asset: hashed with SHA-256, written to a new `artworkDirectory` under `<sha256>.<ext>`, deduplicated by content address, refcounted by the tracks that reference it. `artworkID` **is** the SHA-256 of the delivered image file — one identifier, content-addressed, self-verifying.

New SwiftData model (`Sources/WatchCore/Library/WatchLibraryModels.swift`):

```swift
@Model public final class WatchArtworkAssetModel {
    @Attribute(.unique) public var artworkID: String      // = sha256 of the image file
    public var relativeFilename: String                   // "<sha256>.<ext>"
    public var bytes: Int64
    public var installedAt: Date
    public var validationStateRaw: String                 // reuse WatchAssetValidationState
    // no back-relationship: refcount is computed from track references, like audio
}
```

Supported artwork containers (permanent allow-list, checked before hashing, mirroring `WatchFileInstaller.supportedFileExtensions`): `jpg`, `jpeg`, `png`, `heic`. Reject everything else as `unsupportedAudio`'s artwork analogue (`unsupportedArtwork`, added to `WatchProtocolErrorCode`). The phone emits a single canonical format (JPEG, §7.1); the accept-list stays broad so a future source format still installs.

### §4.2 Three sources, one precedence

Resolution order at render time, highest first:

1. **Custom** — a user-assigned cover (`customArtworkID`). Top precedence: if the user chose it, it wins.
2. **Separate** — the phone's catalog cover for the track/album (`coverArtworkID`).
3. **Embedded** — extracted from the audio file at runtime (current `AVPlayerOutput` behaviour). Fallback only.
4. **Placeholder** — the existing gradient + glyph.

Tiers 1–2 are content-addressed assets delivered ahead of time. Tier 3 is resolved lazily from the already-downloaded audio. The precedence lives in one pure, host-tested type:

```swift
public enum WatchArtworkSource: Equatable, Sendable { case custom, cover, embedded, none }

public struct WatchArtworkResolver {
    /// Pure: given what's installed for a track, which source wins and which file (if any) to load.
    /// `installed(artworkID:)` is a cheap membership test the repository supplies.
    public static func resolve(customArtworkID: String?, coverArtworkID: String?,
                               installed: (String) -> Bool) -> (WatchArtworkSource, artworkID: String?)
}
```

Track-level references are two optional strings added to `WatchTrackModel`, `WatchTrackUpsert`, `WatchTrackSummary`, and (critically) `WatchTrackSnapshot`: `coverArtworkID: String?` and `customArtworkID: String?`. `localThumbnailFilename` is repurposed as a **denormalised cache** of the resolved best-available art filename, written by the artwork installer whenever art for a track is installed/linked, so the player and rows read one field with no join. The `WatchArtworkAssetModel` table remains the source of truth for dedup/refcount; `localThumbnailFilename` is derived.

`WatchTrackSnapshot` gains a single resolved field the player consumes:

```swift
public let artworkFilename: String?   // resolved (custom > cover) local art file, or nil → embedded/placeholder
```

The repository computes it via `WatchArtworkResolver` when projecting snapshots. `WatchPlayer` never learns the precedence rules — it reads `artworkFilename`, loads it if present, and otherwise falls back to embedded extraction (§5.2).

### §4.3 Wire protocol changes (additive only)

- **`WatchCapability.artworkAssets`** — new case. A watch that advertises it will accept artwork file transfers and expose `coverArtworkID`/`customArtworkID`. A phone that sees it in the negotiated set will ship art. Absent → today's behaviour, no art, no error.
- **File-transfer discriminator.** Add `assetKind` to transfer metadata. `WatchConnectivityCoordinator.receiveFile` reads `metadata["assetKind"]`: `"artwork"` → `WatchArtworkInstaller`; `"audio"` **or absent** → `WatchFileInstaller` (back-compatible default).
- **`WatchArtworkFileMetadata`** (new, in `Sources/WatchProtocol/`, mirrors `WatchAudioFileMetadata` shape and `init?(dictionary:)` discipline):

```swift
public struct WatchArtworkFileMetadata: Equatable, Sendable {
    public var artworkID: String        // = sha256 of the image file (content address)
    public var expectedBytes: Int64
    public var sha256: String           // file digest; equals artworkID, kept explicit for the gate
    public var role: WatchArtworkRole    // .cover or .custom (precedence hint; binding travels on the track)
    public var phoneRevision: Int64
    // dictionary/init?(dictionary:) set assetKind = "artwork"
}
public enum WatchArtworkRole: String, Codable, Sendable { case cover, custom }
```

- **Track bindings** ride on the existing catalog payloads, not the file metadata: `coverArtworkID` / `customArtworkID` become optional fields on `WatchTrackSummary` (wire) and `WatchTrackUpsert` (repository boundary). The bytes and the binding travel independently and converge on the watch — a cover can arrive before or after its track (the installer handles audio-before-metadata the same way today via deferred staging; artwork reuses that pattern).

**Rationale for no version bump:** all four changes are additive-optional or default-safe. The capability set is intersected during negotiation, so mixed-version pairs degrade to no-art instead of failing the session — which the exact-match version rule would otherwise force during an independent watch/phone TestFlight rollout.

### §4.4 Watch storage & GC

- New `artworkDirectory` alongside `audioDirectory`, wired in `WatchAppAssembly` (line ~152) and passed to `WatchArtworkInstaller`. A shared `artworkStagingDirectory` for deferred artwork, matching audio staging.
- `WatchArtworkInstaller` (new, `Sources/WatchCore/Sync/`) is a near-copy of `WatchFileInstaller`: validate ext → measure/verify sha256 == artworkID → §2.5 reserve check → atomic move → commit `WatchArtworkAssetModel` + refresh `localThumbnailFilename` on referencing tracks in one transaction → sweep. Duplicate delivery (same content address already present) is acknowledged without a rewrite, exactly like audio.
- **Refcount GC:** an artwork asset is retained while any ready track references it via `coverArtworkID` or `customArtworkID`. On removal/replacement (track removed, `removeAssets`, or a track's art reference changes), recompute references and sweep zero-ref artwork — but only after any replacement is committed (§8.3's "never delete until replacement installed" rule, applied to art). Custom art is **not pinned on the watch** (decided, §11.1): the phone is its durable home (§7.3) and re-sends it on demand, so the watch caches it and reclaims it under the same zero-reference sweep as any cover. A removed-then-re-added track simply re-fetches its custom art; nothing irreplaceable is ever swept.
- Reconciliation (`WatchSyncActor`, manifest path) gains an artwork leg: the watch's manifest reports installed `artworkID`s so the phone can resend a missing cover or drop an orphan. Reuse the existing orphan-adoption/missing-resend machinery; art orphans are files in `artworkDirectory` with no `WatchArtworkAssetModel` row.

### §4.5 Now Playing consumption

`WatchPlayer` loads `currentTrack.artworkFilename` from `artworkDirectory` into a `UIImage` when non-nil and feeds it to both the in-app view (`player.artwork`) and `MPNowPlayingInfoCenter` (§5.2). When nil, the existing embedded-extraction path in `AVPlayerOutput.loadArtwork` runs as the fallback; when *that* is nil, the gradient placeholder shows. Precedence therefore holds end-to-end: custom → cover → embedded → placeholder.

---

## §5 — Now Playing / playback fixes

### §5.1 Surface the silent asset-load failure

In `AVPlayerOutput`, observe item status so a load failure is loud, not invisible:

```swift
private var statusObserver: NSKeyValueObservation?

// in load(url:), right after player.replaceCurrentItem(with: item):
statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
    guard item.status == .failed else { return }
    let ns = item.error as NSError?
    NSLog("AVPlayerOutput: item failed to load — \(item.error?.localizedDescription ?? "unknown"); "
        + "underlying=\(String(describing: ns?.userInfo[NSUnderlyingErrorKey]))")
    Task { @MainActor in self?.onItemFailed?() }
}
// invalidate + nil it in removeItemObservers()
```

Also record a `.routeEvent`/new `.playbackFault` diagnostic via `WatchAppAssembly.shared.diagnostics` on `.failed`, carrying the safe error code (never the raw path). This makes "play does nothing" self-diagnosing on device and lets the engine's existing `onItemFailed` → skip-or-stop logic run instead of hanging on a dead item.

### §5.2 Re-post Now Playing info after the async load; feed resolved artwork

Two edits in `WatchPlayer`:

1. In the `handleCommand` directive `Task`, after `self.duration = self.output.currentDuration`, re-post so the system UI gets the real duration:

```swift
Task { @MainActor in
    await applyWatchDirectives(directives, to: output)
    self.duration = self.output.currentDuration
    if hadStop { self.clearNowPlaying() }
    else if let track = self.currentTrack { self.updateNowPlayingInfo(track: track) }  // ← add
}
```

2. `updateNowPlayingInfo(track:)` already attaches `player.artwork` when present. Ensure `player.artwork` is populated from the resolved `artworkFilename` (§4.5) **before or alongside** the embedded fallback, so the system screen shows custom/cover art, not only embedded. Keep the existing `onArtwork` callback as the embedded-fallback populator when `artworkFilename == nil`.

Net effect on the screen in the bug photo (the watchOS **system** Now Playing surface): real duration + working scrubber, correct cover, and a Play button that either plays or reports why.

> Note for J: that photo is the *system* Now Playing screen, not `WatchNowPlayingView` — watchOS surfaces it whenever audio + `MPNowPlayingInfoCenter` are live, and it composites over your sheet during the transition. These fixes make the system surface correct *when it appears*. Making `WatchNowPlayingView` the canonical **in-app** surface is a committed decision — see task 8 (§9) and §11.2. The system surface still coexists and **cannot be suppressed by any developer API**; only the watch owner's "Auto-Launch Audio Apps" setting governs it, which is why §5.2 keeps its data correct instead of trying to hide it.

---

## §6 — First-play audio route ("Connect Bluetooth")

**Platform reality (do not fight it):** on watchOS, long-form third-party audio requires an eligible output route; with no route the system plays to the built-in speaker on newer hardware or presents its own route prompt. There is no API to force the speaker (`overrideOutputAudioPort(.speaker)` is unavailable on watchOS) and no public route-picker view. So the prompt on first play is partly expected — the goal is to make it **owned, explained, and non-destructive**, not to eliminate it.

Changes:

1. **Pre-flight, app-owned.** Before the first `activate()` of a session, check `AVAudioSession.currentRoute` for a non-built-in output. If none, present the existing `routeProblemCard` ("Choose an Audio Output" / `watch.now.chooseRoute`) *first*, from the app, rather than blindly calling `activate()` and letting the system prompt land over the sheet. The card's button then deliberately calls `retryAudioRoute()` → `activate()`, which is the sanctioned way to summon the system picker — now as a step the user initiated.
2. **Don't leave a half-started player.** If `activate()` throws (or the item never reaches `.readyToPlay` per §5.1), park the engine paused + persisted with the route card visible (the `WatchAudioSessionPolicy` already models this for mid-session route loss; extend it to the first-play case). No silent dead Play.
3. **Remember the choice.** Once a route activates successfully, record it so subsequent plays in the session skip straight to playback. Clear on `mediaServicesWereReset` / route loss.
4. **Speaker-capable hardware.** On hardware/OS that plays to the speaker, `activate()` simply succeeds and audio starts — the pre-flight check sees the built-in route become active and no card is shown. Verify behaviour on a real device; the simulator has no audio hardware (documented in `current_status.md`), so this leg is an owner/device check.

Keep the copy accurate: the card should say headphones/speaker are needed *to route audio off the watch*, not that the app failed.

---

## §7 — Phone-side seam

The iPhone is the **sole origin** of watch artwork — both the IA-style separate cover and any user-customized art. The watch **only displays** art; it never authors or sets it (decided, §11.1). Everything reaching the watch is a **watch-compatible derivative the phone guarantees**.

1. **Always emit a watch-compatible variant (resize-on-download).** The watch must never receive an oversized image. A new deterministic step — `WatchArtworkVariant.make(from:maxEdge:)` (reusing any existing phone downscaler) — takes the chosen source image and, **if its longest edge exceeds the ceiling, downscales to it**; if it is already within the ceiling it is re-encoded to the canonical format at its current size. Ceiling: **≤ 300 px longest edge, JPEG at a fixed quality** (decided, §11.3). It runs **lazily, at the moment a track/root is being transferred to the watch** — the phone never pre-transcodes covers it will not send.
2. **Content-address the derivative, deterministically.** `artworkID = SHA-256(watch-variant bytes)`. Because the resize + encode are deterministic (fixed target dimensions, fixed encoder quality, fixed format), the same source converges on the same hash and dedup on the watch holds. The hash is of the *derivative the watch stores*, never the phone original.
3. **Covers (IA-style separate).** Resolve a genuine cover via `IACoverPicker` / `WidgetArtworkStore` (already rejects IA waveform/spectrogram junk), run it through step 1, and set `coverArtworkID` on the outgoing `WatchTrackSummary`.
4. **Custom art (assigned on the phone only).** The user assigns an image to a track/album **in the iOS app** (reuse the phone's existing image handling). The phone runs it through step 1, sets `customArtworkID` on the track summary, and ships it with `role = .custom`. There is deliberately **no watch-side assignment UI** — the watch renders custom art but cannot set it.
5. **Ship the bytes.** `PhoneWatchSessionFileTransfer.transferArtwork(fileURL:artworkID:role:expectedBytes:sha256:)` builds `WatchArtworkFileMetadata` (`assetKind = "artwork"`) and calls `transport.transferFile`. Ship **both** the cover and (when present) the custom variant as independent content-addressed assets, so the watch keeps the cover as a fallback if the custom asset has not landed; the watch's `WatchArtworkResolver` applies precedence (custom > cover) at render time. Gate on the negotiated `artworkAssets` capability and the existing Wi-Fi/network policy; art rides the same background `file` channel and dedupes on the watch, so re-sends are cheap.
6. **Send order is irrelevant.** Bindings and bytes converge on the watch; a variant that arrives before its track is held in deferred artwork staging and linked when the track upserts (mirror `WatchFileInstaller`'s deferred path).

---

## §8 — Reconciliation, migration, compatibility

- **SwiftData migration:** adding `WatchArtworkAssetModel` and two optional `String?` columns to `WatchTrackModel` is a lightweight/additive schema change. Confirm the container migrates automatically; if a versioned `SchemaMigrationPlan` stage is required, add one. Existing rows get `nil` art references and behave as today until the phone resends covers.
- **Wire compatibility:** covered in §4.3 — additive-optional fields + capability gating, no version bump. Add a test asserting an envelope/summary produced *without* the new fields still decodes on a build that has them (missing-optional → nil), and that `receiveFile` with no `assetKind` still routes to audio.
- **Reconciliation:** extend `WatchManifestPayload`/`WatchSyncActor` with installed `artworkID`s so the phone can resend a missing cover or the watch can adopt an art orphan. Keep it additive (optional field, decode-if-present) — an older phone that ignores it costs only a lazily-refetched cover.

---

## §9 — Task breakdown (one commit each)

Ordered so each commit compiles and is independently testable. Watch-core/protocol tasks are pure and `swift test`-covered; AV/session/phone tasks are device-verified where the simulator can't reach them.

1. **Protocol: artwork types + capability.** Add `WatchCapability.artworkAssets`, `WatchArtworkFileMetadata`, `WatchArtworkRole`, `assetKind` metadata convention, `unsupportedArtwork` error code. Add `coverArtworkID`/`customArtworkID` optionals to `WatchTrackSummary` and `WatchTrackUpsert`.
   *Acceptance:* new types round-trip through `dictionary`/`init?(dictionary:)`; negotiation intersects the new capability; a summary without the new fields still decodes. *Tests:* protocol round-trip + missing-optional decode.

2. **Resolver: precedence (pure).** `WatchArtworkSource` + `WatchArtworkResolver.resolve(...)`.
   *Acceptance:* custom > cover > none; unknown/unavailable id falls through. *Tests:* table of the four tiers incl. missing installs.

3. **Watch store: artwork model + snapshot field.** Add `WatchArtworkAssetModel`; add `artworkFilename` to `WatchTrackSnapshot`; repurpose `localThumbnailFilename` as the resolved-cache; project `artworkFilename` in the repository via the resolver; migration confirmed.
   *Acceptance:* a track with an installed cover projects a non-nil `artworkFilename`; custom overrides cover. *Tests:* repository projection + migration smoke.

4. **Watch install: `WatchArtworkInstaller` + routing.** New installer (content-address, verify, reserve, atomic move, commit, refresh cache, sweep, deferred-before-metadata). Route in `receiveFile` on `assetKind`; wire `artworkDirectory` in `WatchAppAssembly`.
   *Acceptance:* an artwork file installs, dedupes on re-delivery, defers when its track is absent and links on upsert; audio path unchanged; absent `assetKind` still routes to audio. *Tests:* installer outcomes mirroring the audio installer's suite; routing test.

5. **Watch GC + reconciliation.** Refcount sweep for zero-ref artwork (post-replacement); manifest reports installed `artworkID`s; orphan adoption for art files.
   *Acceptance:* removing the last referencing track sweeps the art; a re-referenced art survives; manifest lists art. *Tests:* refcount + orphan scenarios.

6. **`AVPlayerOutput`: status observation (§5.1).** KVO on `AVPlayerItem.status`; `onItemFailed` on `.failed` with logged reason + diagnostic.
   *Acceptance:* a deliberately unplayable URL fires `onItemFailed` and logs; playable URLs unaffected. *Tests:* host test with a spy output for the failure→skip directive path; device check for the real log.

7. **`WatchPlayer`: Now Playing duration re-post + resolved artwork (§5.2, §4.5).** Re-post info after async load; populate `player.artwork` from `artworkFilename`, embedded as fallback.
   *Acceptance:* system Now Playing shows real duration and the resolved cover; embedded still shows when no asset art. *Tests:* extend the smoke that asserts the media clock advances/freezes to also assert non-zero duration is published; device check for the system-screen art/scrubber.

8. **Own Now Playing as the canonical in-app surface (§11.2).** Route every in-app entry — launch with active playback, the root Now Playing chip, the mini-player, and play-start — to `WatchNowPlayingView` (already a `.sheet` on `isShowingNowPlaying`); make it the robust primary surface. Do **not** attempt to suppress the system Now Playing — no developer API exists — and do **not** drop `MPNowPlayingInfoCenter` to hide it (that would kill background transport, lock-screen, and Crown volume). Rely on §5.2 keeping the info center correct so the coexisting system surface is accurate when raised. Leave a code comment at the `MPNowPlayingInfoCenter` call site recording that the system surface is intentionally not suppressed, so no future change chases an opt-out.
   *Acceptance:* from every in-app entry the user lands on `WatchNowPlayingView`; the chip reopens it; transport works there; the system surface, when raised, shows correct duration/art. *Tests:* UI test asserting the entry points land on the `watch.now.*` ids; device check that the app's own screen is the in-app default.

9. **First-play route UX (§6).** Pre-flight route check → app-owned card → deliberate `activate()`; park-paused on failure; remember the route for the session.
   *Acceptance:* with no route, the app's card shows before any system prompt and the player stays paused/safe; after a route connects, playback proceeds and later plays skip the card. *Tests:* policy-level tests for the first-play park/resume; device check for the picker flow.

10. **Phone: watch-variant pipeline + ship covers (§7).** New deterministic `WatchArtworkVariant.make(from:maxEdge:)` (≤ 300 px longest edge, JPEG, fixed quality); resolve covers via `IACoverPicker`/`WidgetArtworkStore`, run through the variant step, hash the derivative, `transferArtwork(...)`, set `coverArtworkID`; capability + network gated; resize happens lazily at watch-transfer time.
    *Acceptance:* an oversized source cover lands on the watch at ≤ 300 px; the same source hashes identically on two runs (deterministic → dedup); no art shipped to a peer lacking `artworkAssets`. *Tests:* variant determinism + max-edge host tests; planner/transfer host tests; end-to-end device check.

11. **Phone: custom-art assignment (§7.4) — phone-only.** In-app assign-image action → variant step (task 10) → hash → `role = .custom` → set `customArtworkID`. The watch renders it but has **no set-on-watch UI**. Custom art is cached on the watch, not pinned (§4.4/§11.1). The full picker/crop/library UI is a candidate follow-on (§11.1), not part of this task.
    *Acceptance:* assigning custom art on the phone makes it win on the watch over the cover; removing then re-adding the track re-fetches it; there is no watch affordance to set art. *Tests:* binding/precedence host test; device check.

12. **Docs + a11y contract.** Update `current_status.md` with the artwork pipeline, the two Now Playing fixes, the first-play route flow, and the own-screen decision + system-surface constraint; add/adjust a11y ids and the contract; note the deferred phone picker UI.
    *Acceptance:* status/contract reflect shipped behaviour. *Tests:* a11y contract test green.

---

## §10 — Test & verification summary

### Local progress (2026-08-30)

Tasks 1–7 are implemented on `main`. The artwork pipeline now includes protocol metadata and
capability negotiation, precedence resolution, SwiftData persistence, content-addressed installation
and routing, storage accounting, refcount cleanup, manifest reporting, and recovery adoption of
hash-valid artwork files. The implementation commit for tasks 4–5 is kept local until explicitly
approved for push.

Tasks 6–7 additionally observe failed `AVPlayerItem` loads, record a safe playback diagnostic,
re-post Now Playing metadata after async duration loading, and load resolved watch artwork before
falling back to embedded art. The task 6–7 commit is kept local until explicitly approved for push.

Next locally: tasks 8–9 (canonical in-app Now Playing routing and first-play audio route UX).

- **`swift test` (CI):** protocol round-trip + missing-optional decode; resolver precedence table; artwork installer outcomes + routing; GC/refcount + orphan adoption; repository projection + migration; failure→skip directive path; first-play park/resume policy; phone planner/transfer/binding.
- **Simulator smoke (pre-commit hook):** existing downloaded-track/album legs, extended to assert published duration is non-zero and that Now Playing renders the resolved cover placeholder path.
- **Owner device checks (cannot be simulated):** real audio output; every in-app entry lands on `WatchNowPlayingView`; the coexisting system Now Playing screen shows cover + working scrubber when raised; the first-play route card precedes the system prompt and playback resumes after a route connects; custom art beats catalog art on the wrist, and survives a remove/re-add.

---

## §11 — Decisions & open items

1. **Custom art — DECIDED (in scope).** Delivered via task 11, building on the protocol fields (task 1) and the phone variant/transfer infra (task 10). **Display-only on the watch:** the watch renders both custom and cover art but has no authoring/set UI — both originate on the phone (§7). **Not pinned on the watch:** authored + stored on the phone (§7.4), cached on the watch, reclaimed under the normal zero-reference sweep and re-sent on demand, so nothing irreplaceable is lost. *Still open:* whether the full picker/crop/library authoring UI on the phone becomes its own follow-on plan, or the minimal in-app assign action (task 11) is enough for now.
2. **Own Now Playing — DECIDED.** `WatchNowPlayingView` is the canonical in-app surface (task 8). The system surface coexists and cannot be suppressed by any developer API — only the owner's "Auto-Launch Audio Apps" setting governs it — so §5.2 keeps it correct rather than hiding it. Dropping `MPNowPlayingInfoCenter` to force-hide it is explicitly rejected (kills background transport + Crown volume).
3. **Art size — DECIDED.** ≤ 300 px longest edge, JPEG at a fixed quality. The phone **always** emits a watch-compatible derivative, downscaling on-download when the source exceeds the ceiling (§7.1); the content hash is of that derivative, so dedup holds. The broad watch accept-list (§4.1) still tolerates other source formats.
