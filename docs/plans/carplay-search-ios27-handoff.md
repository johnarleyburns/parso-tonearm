# CarPlay search: bring it back on iOS 27+, make voice work on iOS 18

**Status (2026-09-24):** T1 to T3 are implemented on top of `5288799`:
- T1 + T2: `feat(carplay): library search back on iOS 27+, as a row in the Library tab`
- T3: `fix(intents): playback intents adopt AudioPlaybackIntent; correct the Siri flow comments`

T4 is a separate **draft** patch on top: `feat(siri): INPlayMediaIntent extension + gated CarPlay Ask Siri cell (DRAFT…)`. Do not merge it until the T4 portal steps are done and the `SIRI_EXTENSION_PROVISIONING_PROFILE_BASE64` secret is added. Until then, the TestFlight job skips with a "missing secrets" notice.

This was written without a macOS toolchain. `Sources/App` is outside `TonearmCore`, and PR CI runs `swift test` only, so run `make project` and build the `Tonearm` scheme in Xcode before merging. The real-car checklist under "Definition of done" is still open. The sections below are the original plan, kept as the rationale.

## 0. What was right, what is now out of date

Earlier sessions today (`feda4bf`, `e3ae1a5`, `3457a7a`, `3e34979`) correctly found why search crashed: `CPAssertAllowedClasses`, because the Search template is not on the Audio category's allow-list. Two conclusions drawn from that are **out of date**. Fix both the code and the comments.

| Earlier claim | Current fact (Apple *CarPlay Developer Guide*, June 2026, Templates table p. 14) |
|---|---|
| "Search is not in the supported set for Audio apps: a hard restriction with **no workaround**" | Audio/video: Search ● **iOS 27 or later**. Earlier iOS still throws. |
| "iOS 27 doesn't exist on any real device yet" (`3457a7a`, `docs/plans/carplay-voice-search-plan.md`) | iOS 27 shipped **2026-09-14** and runs on iPhone 11 and later. |

So on-screen search is an **iOS 27+** feature, not an impossible one. The iOS 18 phone in J's car still must never see it.

Rules from the same guide that still apply:

- The tab bar holds only Grid, Information, List and POI templates. Search can only be pushed (the first crash, which the old code already handled).
- Audio apps get 4 tabs; always read `CPTabBarTemplate.maximumTabCount` (already done in `rootTemplate`).
- Only `CPListTemplate` may be pushed on top of Now Playing.
- The maximum stack depth for audio apps is 5, counting the root.
- The CarPlay Simulator does not enforce several of these checks (see `20c53e2`). Only a real head unit counts as acceptance.

---

## T1: `feat(carplay): restore library search on iOS 27+ (row in Library tab)`

### Design

- Put search in a **row at the top of the Library tab**, not in a new tab. The tab bar then stays the same 3 tabs on every iOS version, so there is zero tab-count risk and the Now Playing button stays visible.
- The row exists **only** when `CarPlaySearchAvailability.templateSupported`.
- The search runs on `LibraryStore.search(_:)`, the FTS5 matcher that phone search and the watch already use. Don't write a second matcher.
- There is **one** selection path: `searchTemplate(_:selectedResult:)`. Result items get no `handler`. The removed code set `item.handler` and made `selectedResult` a no-op, which relied on behaviour CarPlay doesn't document for search results.

### New file `Sources/App/CarPlay/CarPlaySearchAvailability.swift`

```swift
#if !targetEnvironment(macCatalyst)
import CarPlay

/// The single gate for CPSearchTemplate. Apple's CarPlay Developer Guide
/// (June 2026, Templates table): Search is allowed for the Audio category
/// only on iOS 27 or later. Earlier, pushTemplate raises
/// CPAssertAllowedClasses (an ObjC exception Swift can't catch). This was
/// the TestFlight crash behind feda4bf/e3ae1a5.
enum CarPlaySearchAvailability {
    static var templateSupported: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
}
#endif
```

### New file `Sources/App/CarPlay/CarPlaySearchController.swift`

Start from the delegate removed in `e3ae1a5`: `git show e3ae1a5^:Sources/App/CarPlay/CarPlayRootBuilder.swift`, lines ~295 onward. That version compiled under this repo's Swift 6 settings, so keep its isolation pattern. Change it as follows:

```swift
#if !targetEnvironment(macCatalyst)
import CarPlay
import TonearmCore

/// Owns the CPSearchTemplate delegate (CPSearchTemplate.delegate is weak).
/// One instance per CarPlay connection, held by CarPlaySceneDelegate.
@MainActor
final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
    private let interfaceController: CPInterfaceController
    private var hitsByItem: [ObjectIdentifier: (rows: [TrackRow], index: Int)] = [:]
    private var searchTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func present() {
        guard CarPlaySearchAvailability.templateSupported else { return }   // never remove
        let template = CPSearchTemplate()
        template.delegate = self
        Task {
            // Only List may sit on Now Playing, and Search is not a list.
            if interfaceController.templates.contains(where: { $0 is CPNowPlayingTemplate }) {
                _ = try? await interfaceController.popToRootTemplate(animated: false)
            }
            _ = try? await interfaceController.pushTemplate(template, animated: true)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { hitsByItem.removeAll(); completionHandler([]); return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))          // called per keystroke
            guard !Task.isCancelled else { completionHandler([]); return }
            let cap = min(CPListTemplate.maximumItemCount, 24)
            let rows = Array(((try? await LibraryStore.shared.search(query)) ?? []).prefix(cap))
            guard !Task.isCancelled else { completionHandler([]); return }
            hitsByItem.removeAll()
            let items = rows.enumerated().map { index, row -> CPListItem in
                let item = CPListItem(text: row.track.title, detailText: row.artist?.name ?? row.album?.artist)
                hitsByItem[ObjectIdentifier(item)] = (rows, index)      // no item.handler
                return item
            }
            completionHandler(items)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        if let hit = hitsByItem[ObjectIdentifier(item)] {
            AudioPlayer.shared.play(tracks: hit.rows, startAt: hit.index, source: .library)
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
        completionHandler()
    }
}
#endif
```

Every `updatedSearchText` call must invoke **its own** completion exactly once, and every early-return path above does. If the async `popToRootTemplate`/`pushTemplate` overloads trip strict concurrency, use the completion-handler forms nested in each other. **No** suppression or `@preconcurrency` (CLAUDE.md Swift 6 rule).

### Wiring

- `CarPlaySceneDelegate`: `private var search: CarPlaySearchController?`. In `didConnect`, create it when `CarPlaySearchAvailability.templateSupported`, otherwise leave it `nil`. Pass it to `CarPlayRootBuilder.rootTemplate(interfaceController:search:)`. Nil it in `didDisconnect`.
- `CarPlayRootBuilder.libraryTemplate`: when `search != nil`, prepend one item: `CPListItem(text: "Search", detailText: "Songs, artists, albums", image: UIImage(systemName: "magnifyingglass"))`, whose handler calls `search.present()` and then `completion()`.
- The stack depth stays within 5: tab bar(1) → Search(2) → Now Playing(3).

### Comments and docs to correct in the same commit

- `CarPlayRootBuilder.swift` header doc (lines ~26–42): replace "not in the supported-template set … no workaround" with the iOS 27 gate, and cite the guide.
- `CarPlaySceneDelegate.swift` doc (lines ~10–18) still says the carplay-audio entitlement is "currently PULLED". Both `.entitlements` files contain it, so this comment is stale. Fix it.
- `docs/plans/carplay-voice-search-plan.md`: add a dated note under "What does NOT apply here" that iOS 27 shipped on 2026-09-14.

### Guard (CarPlay code lives in `Sources/App`, which `TonearmCore` excludes, so a structural grep gate is the right tool)

Add a section to `scripts/check-ci-guards.sh`. It already runs locally via `make ci-guards` and in CI. Use portable `grep` only:

```bash
# ── CarPlay Search template gate ───────────────────────────────────────────
# CPSearchTemplate is allowed for the Audio category only on iOS 27+ (Apple
# CarPlay Developer Guide, June 2026, Templates table). Earlier iOS aborts in
# pushTemplate (CPAssertAllowedClasses): the feda4bf/e3ae1a5 TestFlight crash.
# Exactly one construction site, behind CarPlaySearchAvailability.
echo "==> CarPlay Search template gate"
search_file=Sources/App/CarPlay/CarPlaySearchController.swift
stray=$(grep -rl --include='*.swift' 'CPSearchTemplate(' Sources | grep -v "^${search_file}\$" || true)
if [ -n "$stray" ]; then
  echo "    CPSearchTemplate constructed outside ${search_file}:"; echo "$stray"; status=1
elif [ -f "$search_file" ]; then
  gate=$(grep -n 'guard CarPlaySearchAvailability.templateSupported' "$search_file" | head -1 | cut -d: -f1)
  ctor=$(grep -n 'CPSearchTemplate(' "$search_file" | head -1 | cut -d: -f1)
  if [ -z "$gate" ] || [ -z "$ctor" ] || [ "$gate" -gt "$ctor" ]; then
    echo "    ${search_file}: the availability guard must precede CPSearchTemplate("; status=1
  elif ! grep -q '#available(iOS 27.0, \*)' Sources/App/CarPlay/CarPlaySearchAvailability.swift; then
    echo "    CarPlaySearchAvailability must gate on iOS 27.0"; status=1
  else
    echo "    OK"
  fi
else
  echo "    OK (no search controller)"
fi
```

Run `bash scripts/check-ci-guards.sh` twice: once green, and once after temporarily adding a stray `CPSearchTemplate()` to another file, to prove the gate fails. Revert the stray line.

Also run a real `xcodebuild` for the `Tonearm` scheme. `swift test` does not compile `Sources/App`.

---

## T2: `fix(carplay): disable the search row while the car locks out the keyboard`

Many cars turn the keyboard off while moving. iOS disables it inside the template, but Apple's guidance is that the app should adjust its own entry points (use `CPSessionConfiguration` to observe `limitedUserInterfaces`).

- `CarPlaySceneDelegate` owns a `CPSessionConfiguration(delegate:)` for the connection's lifetime. The delegate must be an `NSObject`; the scene delegate already is one, via `UIResponder`.
- In `sessionConfiguration(_:limitedUserInterfacesChanged:)`, rebuild the Library tab's sections. Keep a reference to the Library `CPListTemplate`: return it from the builder, or store it on the scene delegate. While `.keyboard` is limited, the search row stays in place with `isEnabled = false` and detail text "Available when parked". Disable it rather than removing it so the list doesn't shift under the driver's finger. The copy must never tell the driver to use the phone (Guidelines for all CarPlay apps, #2).
- Seed the initial state from `configuration.limitedUserInterfaces.contains(.keyboard)`.

---

## T3: `fix(intents): playback intents adopt AudioPlaybackIntent; correct the Siri flow comments`

These changes are for iOS 18, the phone that is actually in the car.

1. In `Sources/Intents/TonearmAppIntents.swift`, change `TonearmPlayPlaylistIntent`, `TonearmPlayArtistIntent`, `TonearmPlaySongIntent` and `TonearmResumeIntent` from `AppIntent` to **`AudioPlaybackIntent`** (iOS 17+ and macOS 14+, both below this repo's floors). It is the App Intents protocol for intents that start or change audio playback. It tells the system that this intent, run in the app process with `openAppWhenRun = false`, is meant to start audio. Keep the `ProvidesDialog` results. Voxglass's `docs/INTENTS_LIVE_ACTIVITY_SIRI_PLAN.md` made the same choice.
2. Correct the claim in `CarPlayRootBuilder.swift` (the removed assistant-cell block) and in `3e34979`'s rationale. A single sentence like **"Hey Siri, play Hotel California in Platterhead" does not work today.** The registered phrases are "Play a song in Platterhead" / "Play a track in Platterhead"; Siri then asks for the `songTitle` value in a follow-up turn. App Shortcut phrases can't take a free-text `String` parameter. One-sentence media requests need `INPlayMediaIntent` (T4), or the iOS 27 App Intents `.audio` schema (`AudioSearch`, out of scope here).
3. Verify on the device, connected to the car: "Hey Siri, play a song in Platterhead" → "Hotel California" → playback starts with the phone locked. Also check "Hey Siri, resume Platterhead".

---

## T4 (optional; needs J first): one-sentence Siri media requests + the CarPlay "Ask Siri" cell

Only start this after J has done the portal work. It is what `3e34979` correctly said is missing.

**Portal steps (J, before any code):**
- Enable Siri on the `guru.parso.tonearm` App ID.
- Create an App ID for the new Intents extension, with the `group.guru.parso.tonearm` app group.
- Regenerate the provisioning profiles. The last CarPlay entitlement change failed TestFlight archive because "Platterhead Profile" was stale.

**Code:**
- New target `TonearmIntents` (`com.apple.intents-service`) in `project.yml`, embedded in `Tonearm`. Its Info.plist has `NSExtension → NSExtensionAttributes → IntentsSupported: [INPlayMediaIntent]` and `SupportedMediaCategories: [INMediaCategoryMusic]`.
- Extension handler: keep it thin. `LibraryStore`'s SQLite lives in the app's Application Support, not the app-group container, so the extension **can't** see the library. Resolve by echoing the spoken search back as a placeholder `INMediaItem`, with the query encoded in `identifier`. Then return `.handleInApp`:

```swift
final class IntentHandler: INExtension, INPlayMediaIntentHandling {
    override func handler(for intent: INIntent) -> Any { self }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let q = intent.mediaSearch?.mediaName ?? ""
        let artist = intent.mediaSearch?.artistName ?? ""
        let item = INMediaItem(identifier: "q:\(q)|a:\(artist)", title: q.isEmpty ? "Resume" : q,
                               type: q.isEmpty ? .unknown : .song, artwork: nil)
        return [.success(with: item)]
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil)
    }
}
```

- App side: add `@UIApplicationDelegateAdaptor` to `TonearmApp` and implement `application(_:handlerFor:)`. Return an in-app `INPlayMediaIntentHandling` whose `handle` decodes the identifier. It runs the **existing** `TonearmIntentRunner.playSong(title:artist:)`, or `.resume` when the query is empty, and returns `.success`, or `.failureUnknownMediaType`/`.failure` when there's no match. Zero new matching logic. (Public reference for this split: jubishop/podhaven PR #699.)
- Siri authorization: `NSSiriUsageDescription` in the app's Info.plist. Call `INPreferences.requestSiriAuthorization` **only** from a user-tapped Settings row, per the CLAUDE.md "no silent/magic" rule. Settings shows the current status.
- Put the assistant cell back **only** when `INPreferences.siriAuthorizationStatus() == .authorized`, via `CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .playMedia)` on the three tab lists.
- Acceptance is on a real car only: the CarPlay scene opens (the `3e34979` failure mode), the cell appears, and "Play Hotel California on Platterhead" plays with the phone locked.

---

## Definition of done (T1 to T3)

- [ ] `swift test` green (pre-commit hook; no `--no-verify`) plus a real `xcodebuild` of `Tonearm` (iOS) and `TonearmMac`.
- [ ] **Real car, iOS 18.x (J's current phone):** no Search row. Browse all three tabs and play from each. No crash. The Siri two-turn flow from T3 plays with the phone locked.
- [ ] **Real car, iOS 27.x** (any iPhone 11 or later can update): the Search row is present. Type "hotel" → tap a result → Now Playing. Back → results. Open Search from a list pushed while Now Playing was on the stack: no crash. While moving, the row goes disabled.
- [ ] Record both runs in the commit message. The CarPlay Simulator alone is **not** acceptance for anything in this plan.

## Do not

- Put `CPSearchTemplate` in `CPTabBarTemplate(templates:)`.
- Try to catch the NSException or probe support by pushing and seeing what happens.
- Re-add `CPAssistantCellConfiguration` without T4's Intents extension and Siri authorization.
- Add a 4th tab for search. It would work (the audio limit is 4), but the Library row avoids a tab bar that changes shape by iOS version.
