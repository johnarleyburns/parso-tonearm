# Native Mac app plan — replacing Catalyst

Status: **ready for implementation**. Supersedes the Catalyst-build portion
of [`docs/plans/macos-app-cloud-sync-plan.md`](macos-app-cloud-sync-plan.md)
(§3 specifically) after the owner tried the working Catalyst build this
session and decided against it: *"i've decided i don't like catalyst
interface I want the real mac interface... but keep the 'large ipad-style'
UI for ipads."* That is the final call — this plan does not re-litigate
Catalyst vs. native; it plans the native path, reusing everything reusable
from the Catalyst-era work rather than starting over.

**What does not change**: the iPhone and iPad builds keep their current UI
exactly as-is. This plan adds a *third*, separate native macOS app target
alongside them — it does not touch `Sources/Features/`'s existing phone/iPad
layouts at all except where a shared file needs a Mac-specific branch (§2).

Mockups: [`docs/plans/mockups/native-mac-app-mockups.html`](mockups/native-mac-app-mockups.html)
— covers every real screen in the app (Listen, My Music/Library, Playlists,
Now Playing, Up Next, Find by Sound, Sound Index status, Onboarding), the
full ⌘, Preferences window (all four panes), every sheet/dialog (Add Music
as a real NSOpenPanel, Add Server, Sources, Create/Add-to-Playlist, Edit
Track Info, Track Detail, EQ, Tools, Jamendo, Remote Connector Guide,
Ambient Playlist, Apple Watch's Mac-specific explainer), the real system
menu bar with File/Edit/Playback actually open, the `MenuBarExtra` status
item, and the right-click context menu — indexed by a sticky table of
contents at the top of the file.

---

## 0. What stays from the Catalyst work, what goes

Re-verified directly, not assumed:

**Stays, unconditionally — platform-agnostic Swift, has nothing to do with
Catalyst vs. native:**
- The CloudKit discovery-index sync work (`discovery_embedding`/
  `discovery_track_analysis` `syncID` columns, `RecordMapping` additions,
  `DiscoveryEmbeddingSyncDecision`, `CloudSyncEngine` push/pull wiring). None
  of it references UIKit, Catalyst, or any Mac-specific API.
- The GPU-preferred thermal policy (`DiscoveryExecutionPolicy`,
  `SchedulingSampler`'s engine-decision tracking). Also platform-agnostic.
- `parso-audio-engine` 1.2.2 (the `AudioBufferListPointer` fix) — needed
  regardless of which Mac UI approach is used, since `ParsoAudioPlayback`
  is a dependency either way.

**Goes — remove once the native target replaces Catalyst as the Mac path:**
- `project.yml`'s `SUPPORTS_MACCATALYST: "YES"`,
  `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: "NO"`, and the `"6"` in
  `TARGETED_DEVICE_FAMILY: "1,2,6"` (line ~195) — these three lines are the
  entire Catalyst enablement; deleting them drops the Catalyst build
  destination cleanly. `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: "YES"` is a
  **separate, unrelated** setting (the "runs the iOS binary as-is on Apple
  Silicon" fallback from Phase 0 research last session) — leave it; it costs
  nothing and doesn't require Catalyst.
- `scripts/patch-catalyst-embed-filters.py` and its call from
  `scripts/generate-project.sh` — this exists solely to stop the Catalyst
  build from trying to embed iOS/watchOS extensions into a macOS product. A
  genuinely separate native target won't embed those extensions in the
  first place (its own target's `dependencies:` list simply won't include
  them), so this workaround has nothing left to patch.

**Stays, and needs a second look, not removal — don't act on assumption:**
- `Sources/App/CarPlay/CarPlaySceneDelegate.swift` /
  `CarPlayRootBuilder.swift`'s `#if !targetEnvironment(macCatalyst)` guard.
  CarPlay is still fully relevant to the iPhone build regardless of what
  happens on Mac — **do not remove this gate**. It was only ever needed
  because Catalyst reuses the *same* `Tonearm` target as iOS; once Catalyst
  support is removed from that target (previous bullet), the guard becomes
  permanently true (never compiled out) and harmless to leave in place. Not
  worth a separate cleanup pass — removing it buys nothing and risks a
  regression if Catalyst is ever revisited.

---

## 1. Target architecture

**New target: `TonearmMac`**, a fully separate native macOS app target in
`project.yml`, `platform: macOS`, NOT a second variant of the existing
`Tonearm` target. Reasoning: xcodegen's `platform:` is one value per
target — a target can be `iOS` or `macOS`, and Catalyst is what let one
`platform: iOS` target *also* run on Mac. A genuine native app needs its own
target with its own `Info.plist`, its own deployment target, its own
entitlements file, and — critically — its own `App` entry point (`@main
struct TonearmMacApp: App`), since window/scene structure differs
meaningfully between `WindowGroup` usage patterns that feel right on iPhone
vs. Mac (§3).

**Code sharing**: `TonearmMac` depends on the exact same `TonearmCore` and
`TonearmDiscovery` SwiftPM library products the iOS target already uses —
zero duplication of business logic. It also reuses `Sources/Features/` and
`Sources/DesignSystem/` SwiftUI views directly where they're already
UIKit-free (most of them, §2) — those files are shared, not copied for a
Mac-specific version. Only the handful of files with real UIKit
dependencies get a Mac-specific counterpart (§2), following this
repo's existing pattern of `#if os(macOS)` branches inside a shared file
(preferred, keeps one source of truth) or a parallel `*+Mac.swift` file
where the implementations are different enough that branching inline would
hurt readability (used for the two `UIViewRepresentable` wrappers
specifically, since an `NSViewRepresentable` conformance is a genuinely
different protocol, not a `#if`-able body).

`project.yml` sketch:

```yaml
targets:
  TonearmMac:
    type: application
    platform: macOS
    sources:
      - path: Sources
        excludes: [ <same excludes as Tonearm, plus CarPlay/**> ]
      - path: Resources
        excludes: [ "Models/**" ]
    dependencies:
      - package: TonearmCore
      - package: TonearmCore
        product: TonearmDiscovery
      - package: ParsoAudioEngine
        product: ParsoAudioStreaming
      - package: ParsoAudioEngine
        product: ParsoAudioPlayback
      # No Share/Widgets/Watch extension embeds — a genuinely separate
      # target simply never lists them as dependencies, unlike Catalyst's
      # workaround (§0) which had to patch them back OUT.
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: guru.parso.tonearm   # same as iOS — required for Universal Purchase, §4
        MACOSX_DEPLOYMENT_TARGET: "14.0"                # Sonoma — matches CloudKit sync's iOS-17-equivalent API floor
        ENABLE_APP_SANDBOX: "YES"                       # §4
        CODE_SIGN_ENTITLEMENTS: Sources/AppMac/TonearmMac.entitlements
    info:
      path: Sources/AppMac/Info.plist
```

`CarPlay/**` gets excluded from `TonearmMac`'s sources the same way it's
excluded from every other non-phone target already (`TonearmShareExtension`,
`TonearmWidgetsExtension` already exclude paths that don't apply to them) —
CarPlay is meaningless on Mac and the framework itself isn't linked, so this
is a straightforward exclusion, not a `#if` gate.

---

## 2. Code sharing — re-verified fresh, not from the old research pass

The earlier research (before this session's newer Discovery/Onboarding work
landed) found 2 UIKit-dependent files. Re-grepping `Sources/Features/` +
`Sources/DesignSystem/` just now for real usage (not stray comments) finds
**14 files**, in three real categories:

### 2a. Genuine `UIViewRepresentable` wrappers — need an `NSViewRepresentable` counterpart

| File | Wraps | Mac approach |
|---|---|---|
| `Sources/Features/Components/AirPlayButton.swift` | `AVRoutePickerView` (UIKit-only, confirmed no AppKit equivalent exists) | Mac has no in-app AirPlay picker API at all — AirPlay output selection on macOS goes through the **system Sound menu-bar item** or `AVRoutePickerView`'s absence means route selection isn't app-embeddable on Mac the way it is on iOS. Real Mac apps in this position (Music.app included) don't show an in-app AirPlay button — they rely on the system's own output picker. Recommendation: **omit the AirPlay button entirely on the Mac build** (`#if !os(macOS)` around wherever it's placed in Now Playing), rather than inventing a nonstandard substitute. Not a porting task — a removal. |
| `Sources/DesignSystem/LoopingVideoView.swift` | Custom `LoopingPlayerUIView : UIView` | Real, small port: `NSViewRepresentable` wrapping an `NSView` subclass with a `CALayer`-backed `AVPlayerLayer`, mirroring the existing looping/seek logic. Used for onboarding's animated splash background — cosmetic, not launch-blocking if deferred to a later phase (a static frame is a fine placeholder). |
| `Sources/Features/Ingest/AddServerSheet.swift`'s `PasteCapableTextField` | Custom `PasteEnabledTextField : UITextField` | The reason this exists on iOS is that a plain SwiftUI `TextField` doesn't reliably support paste in some sheet-presentation contexts (a real report this app already worked around). macOS's `TextField` doesn't have that same paste limitation — verify this at implementation time, but the likely fix is simply **using the plain SwiftUI `TextField` on Mac**, no wrapper needed at all. |
| `Sources/Features/Discovery/IndexStatusView.swift`'s `ActivityView` | `UIActivityViewController` (share sheet) | Mac equivalent is `NSSharingServicePicker`, wrapped via `NSViewRepresentable` (there's no `UIActivityViewController` analog that's a simple protocol swap — this needs a small real implementation, maybe 20-30 lines). Used for exporting diagnostics; not launch-blocking, can ship Phase 2/3. |

### 2b. `UIImage`-as-artwork-type — a real, moderate porting surface, not 2 files

`Sources/DesignSystem/ArtworkView.swift`, `KeywordArtwork.swift`,
`Sources/Features/Sources/RemoteArtworkImageView.swift`,
`Sources/Features/NowPlaying/NowPlayingView.swift` (and by extension every
call site that stores/passes artwork) use `UIImage` as the concrete artwork
type throughout — for caches, `@State` properties, and `Image(uiImage:)`
construction. `UIColor` also appears (`ArtworkView.swift` line ~125,
`AirPlayButton.swift`'s tint colors).

This is genuinely more surface area than "2 files," but it's mechanical, not
architectural: introduce one small shared typealias/wrapper in
`Sources/DesignSystem/` —

```swift
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#endif
```

— and replace `UIImage`/`UIColor` with `PlatformImage`/`PlatformColor`
across those ~6 files. `Image(uiImage:)` becomes a tiny cross-platform
`Image(platformImage:)` helper (SwiftUI's `Image` init differs by platform:
`Image(uiImage:)` vs `Image(nsImage:)`). `ArtworkService.swift` (which
actually decodes/caches artwork bytes into `UIImage` today) needs the same
treatment at its `UIImage(data:)` call sites. Real work, comfortably a few
hours, not a redesign.

### 2c. `#if canImport(UIKit)`-guarded files — verify at implementation time, don't assume

`Sources/Features/Discovery/IndexStatusModel.swift`,
`DiscoverySearchView.swift` both guard their entire body with `#if
canImport(UIKit) && !os(watchOS)`. On a native Mac target, `canImport(UIKit)`
is false, so **whatever these files provide becomes entirely unavailable on
Mac unless the guard is loosened or given a macOS branch** — this could be
substantial (Discovery/Search status UI sounds core, not peripheral). This
plan does not resolve it here because it requires reading what's actually
inside those guards in full, which is real implementation work, not
planning — flagged clearly as the first thing to investigate in Phase 1, so
it doesn't surface as a surprise mid-build. `Sources/Features/
Onboarding/AnimatedSplashView.swift`'s guard already has (per its own
existing code) a fallback path outside the UIKit branch — lower risk,
verify but likely fine as-is.

### 2d. Bare `import UIKit` with no other UIKit symbols caught

`Sources/Features/Ingest/AddSourceSheet.swift`,
`Sources/Features/Sources/SourceDetailView.swift` — only the import line
matched; no `UIColor`/`UIImage`/etc. found in the same grep. Likely either
an unused leftover import (delete it, trivial) or a UIKit symbol my grep
pattern didn't catch (e.g. `UIPasteboard`, `UIActivityIndicatorView`) —
verify directly at implementation time; low risk either way given the
narrow surface.

**Everything else** — `Sources/Domain`, `Sources/Data`, `Sources/Discovery`,
`Sources/Audio`, `Sources/Sync`, `Sources/Remote`, `Sources/Media` (business
logic, all already excluded from the Xcode app target and compiled as
SwiftPM library products — inherently UIKit-free since that's how the
existing `TonearmCore`/`TonearmDiscovery` products already build for
`.macOS(.v15)` per `Package.swift`'s own `platforms:` list), and the large
majority of `Sources/Features/`'s remaining ~40 SwiftUI view files — need
zero changes. This was true in the earlier research and remains true now;
the newly-found UIKit files above are additive, not a correction of that
core finding.

---

## 3. The native Mac UI

This is where "native" actually pays off over Catalyst — genuine `NSWindow`
chrome, not UIKit-on-Mac. Concretely, building on
`macos-app-cloud-sync-plan.md` §3.2's still-valid cross-platform SwiftUI
pieces (`MenuBarExtra`, `NavigationSplitView`, `.keyboardShortcut`,
`MPRemoteCommandCenter` hardware media keys — none of these were ever
Catalyst-specific; they work identically in a native SwiftUI-for-Mac app,
often *more* reliably since there's no UIKit-compatibility-shim layer in
the way):

- **Real system menu bar** (File/Edit/View/Window/Help), not just a
  `MenuBarExtra` status item. SwiftUI's `.commands { }` modifier on the
  `WindowGroup` scene builds real `NSMenu` entries — e.g. File > Add Music
  Folder…, File > Add Server…, Edit > Find (wired to the existing library
  search), View > toggle sidebar, Window > standard window-management
  items macOS provides for free. `MenuBarExtra` (the Now Playing panel,
  §3.2's original scope) is a *second*, additional piece — real Mac apps
  commonly have both a system menu bar and a menu-bar-extra status item;
  they aren't alternatives to each other. See mockup [§ File](mockups/native-mac-app-mockups.html#m-file),
  [§ Edit](mockups/native-mac-app-mockups.html#m-edit),
  [§ Playback](mockups/native-mac-app-mockups.html#m-playback),
  [§ status item](mockups/native-mac-app-mockups.html#m-extra).
- **Sidebar + toolbar**, not sidebar alone: `NavigationSplitView` for the
  Listen/My Music/Settings destinations (as already planned), with a real
  `.toolbar { }` on the detail column — search field, view-mode toggles —
  using `ToolbarItem`, which renders as genuine `NSToolbar` chrome
  (unified title bar, the traffic lights sitting inline with toolbar
  icons) rather than Catalyst's UIKit-flavored nav bar. See mockup
  [§ Listen](mockups/native-mac-app-mockups.html#w-listen) and
  [§ Library](mockups/native-mac-app-mockups.html#w-library) for the
  shell in context; every other primary window (Playlists, Now Playing, Up
  Next, Find by Sound, Sound Index, Onboarding) is mocked up the same way —
  see the mockup file's own table of contents.
- **Right-click context menus**: SwiftUI's `.contextMenu { }` already
  renders as a real `NSMenu` on Mac automatically — the existing
  `TrackContextMenu`/track-row context menus (already built for iOS
  long-press) likely need zero code changes here, just verification they
  read well as a right-click menu (spacing/icon conventions differ
  slightly; a quick pass, not a rewrite). See mockup
  [§ Context menu](mockups/native-mac-app-mockups.html#x-context).
- **Preferences window, not a Settings sidebar tab**: real Mac apps use
  ⌘, for a dedicated Preferences window (`Settings { }` scene in SwiftUI,
  Mac-only API, renders as a proper small floating preferences panel with
  a toolbar of preference-pane icons if organized that way). Recommendation:
  **yes, make Settings a real `Settings { }` scene for `TonearmMac`**, reusing
  the same underlying `SettingsView` content (which is already just
  SwiftUI, no UIKit) inside Mac-appropriate window chrome instead of a
  sidebar destination — its four existing sections (Playback, Library &
  Storage, Account & About, Advanced) become four preference panes
  unchanged. See mockup [§ Playback](mockups/native-mac-app-mockups.html#p-playback),
  [§ Library](mockups/native-mac-app-mockups.html#p-library),
  [§ Account](mockups/native-mac-app-mockups.html#p-account),
  [§ Advanced](mockups/native-mac-app-mockups.html#p-advanced).
- **Every sheet/dialog gets a Mac-appropriate mockup, not an assumed
  1:1 port**: two are genuinely re-thought — Add Music Folder becomes a
  real `NSOpenPanel` (mockup [§ Add Music](mockups/native-mac-app-mockups.html#s-addmusic))
  instead of iOS's document-picker sheet, and Apple Watch settings become
  an explainer rather than download-management controls, since a Mac has
  no paired-Watch relationship the way iPhone does (mockup
  [§ Apple Watch](mockups/native-mac-app-mockups.html#s-watch)). Every
  other sheet (Add Server, Sources, Create/Add-to-Playlist, Edit Track
  Info, Track Detail, EQ, Tools, Jamendo, Remote Connector Guide, Ambient
  Playlist) keeps the same sheet pattern — see the mockup file's table of
  contents for each.
- **Window restoration**: SwiftUI's `WindowGroup` gets standard
  frame/state restoration for free on macOS (no extra code) as long as the
  window has a stable identifier — verify this "just works" during Phase
  1, since it's a zero-cost check, not a build task.
- **Drag-and-drop from Finder**: a real, worthwhile native capability not
  in Catalyst's original scope — `.onDrop(of: [.fileURL], ...)` on the
  library view, reusing the exact same folder-import logic the existing
  "Add Folder" sheet already calls into (`IngestService`). Scope as Phase
  2/3, not launch-blocking.
- **Touch Bar**: not worth building. Apple has not shipped a new
  Touch-Bar-equipped Mac since 2023, and SwiftUI's Touch Bar API surface
  itself is effectively frozen — omit from this plan entirely rather than
  spend any phase on it.
- **Multi-monitor / resize**: SwiftUI `WindowGroup` handles this correctly
  by default on macOS; the only real work is choosing sensible
  `.defaultSize`/`.frame(minWidth:minHeight:)` values so the sidebar layout
  doesn't break at a very narrow window width — a small tuning pass in
  Phase 2, not its own phase.

---

## 4. App Store distribution — Universal Purchase

**Sandboxing** — confirmed directly: `Sources/App/Tonearm.entitlements` has
no `com.apple.security.app-sandbox` key at all today. The Mac App Store
requires App Sandbox; the iOS App Store does not gate on it the same way
(iOS's own OS-level sandboxing is unconditional and separate). `TonearmMac`
needs its **own** entitlements file (not a shared one — a sandboxed Mac app
and an unsandboxed-by-default iOS app have genuinely different entitlement
needs) with, based on this app's real feature set:
- `com.apple.security.app-sandbox` = true (required)
- `com.apple.security.network.client` (streaming, Jamendo/archive.org,
  remote libraries, CloudKit)
- `com.apple.security.files.user-selected.read-write` (local folder
  import — sandboxed apps need this instead of arbitrary filesystem access;
  the existing security-bookmark-based local-file approach this app already
  uses for iOS's own sandbox should port directly, since it was already
  designed around exactly this constraint)
- `com.apple.security.application-groups` / iCloud entitlements — same
  values as the iOS entitlements file (`group.guru.parso.tonearm`,
  `iCloud.guru.parso.tonearm`) so CloudKit sync (§0) works identically
  across platforms
- No `com.apple.developer.carplay-audio` (meaningless on Mac, omit)

**Background audio**: unlike iOS's `UIBackgroundModes: [audio]`, a sandboxed
Mac app doesn't need a special entitlement for background audio playback —
standard `AVAudioEngine`/`AVPlayer` audio continues while the app is in the
background on macOS by default, no equivalent Info.plist key needed. Verify
this holds once real playback is running (Phase 1 acceptance check), but no
entitlement to add speculatively.

**Deployment target**: macOS 14 Sonoma, matching the CloudKit sync work's
iOS-17-equivalent API floor already established this session (`@available
(iOS 17.0, *)` gates on `CloudSyncEngine`/`CKSyncEngine` throughout) —
picking a lower macOS target would need extra availability shims for no
real benefit given the target audience (anyone buying a new or recent Mac
capable of running this app's CoreML indexing workload is on a
current-enough OS).

**Notarization**: standard for any Mac app distributed outside a plain
local Xcode run — the Mac App Store path handles this automatically as part
of App Store Connect's own submission/review pipeline (unlike direct/
"Developer ID" distribution outside the App Store, which needs an explicit
`notarytool` step this app won't need if going through the App Store only,
which is what "universal install" implies here).

**Universal Purchase — the actual mechanism** (stated from well-established,
current Apple platform knowledge; a live-fetch attempt against Apple's own
docs during this research pass returned only 404s/unrenderable JS shells,
so treat this as confirmed-but-not-freshly-cited, and do one final check in
App Store Connect at submission time rather than trusting this blindly):
Universal Purchase is **not** Catalyst-exclusive — it works for any macOS
app, Catalyst or fully native, under three conditions: (1) the same
`PRODUCT_BUNDLE_IDENTIFIER` across every platform target (already the plan
above uses `guru.parso.tonearm` for `TonearmMac`, matching iOS exactly);
(2) all platform builds submitted under the **same App Store Connect app
record** (adding macOS as an additional platform to the existing app via
App Store Connect's own "+" platform-add flow, not creating a second,
separate app listing); (3) the same Apple Developer Team account (already
true, team `3264Y8YUGV`). No Catalyst requirement anywhere in this
mechanism — it's fundamentally about the shared bundle ID + app record, not
which UI framework built the binary.

---

## 5. Phased effort estimate

| Phase | Scope | Rough effort |
|---|---|---|
| **0** | Sandbox entitlements file + `TonearmMac` target skeleton in project.yml, builds and launches a blank window linking the shared business-logic packages | Hours — mechanical, mirrors the Catalyst target-creation work already done once this session |
| **1** | `PlatformImage`/`PlatformColor` typealiases + port the ~6 artwork-touching files (§2b); resolve the two `#if canImport(UIKit)`-guarded Discovery files (§2c) — investigate what's actually inside them first; real UI runs end-to-end (library browses, playback works) even if visually still basic | Substantial — the actual bulk of "does this compile and run for real" work |
| **2** | Real Mac-idiom UI: sidebar + toolbar, system menu bar via `.commands`, `Settings { }` Preferences window, drag-and-drop import | Substantial — this is the actual "feels native" payoff the owner asked for |
| **3** | `MenuBarExtra` Now Playing panel, keyboard shortcuts, hardware media keys verification, the 3 remaining `UIViewRepresentable` ports (AirPlay-button removal, LoopingVideoView, ActivityView/NSSharingServicePicker) | Moderate — mostly independent, parallelizable pieces |
| **4** | App Store Connect: add macOS platform to the existing app record, sandboxed Release build + signing/provisioning for Mac App Store (a new, separate provisioning profile from the iOS one, same bundle ID), first TestFlight-for-Mac (or direct submission) pass | Moderate — mostly account/portal configuration and one real submission cycle, not code |

Phases 0-1 are the honest "does this actually work" gate — nothing in
Phase 2+ is worth starting until a bare native window is genuinely playing
audio from the shared library. Phases 2 and 3 can run concurrently once
Phase 1 is solid, since they touch largely non-overlapping files (window
chrome/menu commands vs. the remaining view-wrapper ports).
