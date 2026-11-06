# Remote Libraries — Future Enhancements

Not scheduled work. This is a holding pen for remote-library ideas that came up while building
"remember the last browsed folder" and "Add This Folder to My Music"
(`docs/plans/misty-singing-thunder.md`, Parts A/B) and the provider-coverage research done
alongside it, so none of it gets lost. Pull an item out of here into its own plan when it's
actually picked up.

## Deferred from the folder-scoped bulk-import work

- **Connect-time folder scoping.** Let the user pick a root folder when first connecting Google
  Drive/Dropbox/OneDrive/pCloud, the way `AddServerSheet`'s `folderPath`/`originalURL` already
  does for SMB. Real and consistent, but not required — "Add This Folder to My Music" (Part B)
  already works on any folder at any time without touching the connect flow.
- **Ongoing auto-sync for remote sources.** Make `Source.followUpdates`/a `watch`-style flag real
  so newly-added files in an already-imported Drive folder get picked up automatically, instead
  of the user re-running "Add This Folder to My Music" by hand. `followUpdates` and
  `touchSourceResolved(id:)` are fully dead code today (set once at add-source time for IA lists
  only, read by nothing) — this is new infrastructure, not wiring up something dormant, and per
  CLAUDE.md's "no silent background work" rule it would need its own visible status surface
  (what's syncing, why, since when) plus a stop/pause/retry control designed in the same change,
  not as a follow-up.
- **Multi-select / per-file checklist UI for bulk import.** Deliberately not built — the folder
  scope plus existing `kind == .audio` filtering is the control surface; a 100+-row checklist
  would undercut "without clicking every item," which was the whole point of the request.
- **WebDAV/SMB path staleness on rename.** Pre-existing, not introduced by Part A's "remember
  last folder" feature — `RemoteNode.path` is a real permanent item ID for every cloud-drive/
  Subsonic/Jellyfin/Plex/archive.org provider, but WebDAV/SMB use genuine nested name-based
  paths that can go stale if a folder is renamed. Part A already self-heals this one case (a
  remembered path that fails to browse falls back to root and clears itself), but the general
  "renamed folder breaks a stored path" risk elsewhere is unaddressed.
- **`JamendoBrowseView`'s separate scroll-position state.** Unrelated to Source-level folder
  memory; its own, smaller, pre-existing gap.

## Provider coverage — status

Box, Yandex.Disk, an Ampache/Funkwhale hardening pass for the existing Subsonic connector, and
Emby moved from "surveyed" to **active implementation** — see
`docs/plans/misty-singing-thunder.md`. Nextcloud/ownCloud needed no new code at all: the existing
generic `WebDAVProvider` is fully host-agnostic, and `RemoteConnectorCatalog`'s `.webDAV` entry
already names it in its subtitle.

The Yandex.Disk sanctions/App-Store-risk question that gated it here previously was resolved by
direct research (OFAC SDN lookup + Lukoil sanctions history + Wikipedia's account of Yandex's 2024
restructuring): Yandex/Yandex N.V. was never itself sanctioned, a 15% minority stake by a
since-sanctioned investor (Lukoil) in the post-restructuring Russian entity doesn't trigger OFAC's
50%-aggregate blocking rule, and a real competitor (Infuse) ships Yandex.Disk support on the US App
Store today — see the "already done" plan for the full writeup. Verdict: proceed, no longer gated.

**Still deferred, no specific demand yet:**
- **Synology** — NAS devices already expose standard SMB/WebDAV, both already supported; a
  bespoke DSM/Synology Drive API would be new infrastructure for marginal gain over what's
  already there.
- **Koofr** — real 10GB-free tier, but no public REST/OAuth API docs could be found (dev-docs
  paths 404'd). A maybe, not a yes, until someone finds live API docs.

**Dead ends — don't revisit absent a platform policy change:**
- **iCloud Drive** — no public third-party OAuth API exists for browsing a user's general iCloud
  Drive tree; Apple's third-party story is CloudKit (app-scoped containers for an app's own data),
  not account-wide Drive access.
- **Amazon Drive/S3** — Amazon Drive (the consumer service) was discontinued (shutdown completed
  Dec 31, 2023); S3 is pay-per-use developer object storage, not a consumer "sign in with your
  library" product.
- **SoundCloud** — OAuth 2.1+PKCE is solid, but SoundCloud's own docs require a paid Artist Pro
  subscription just to register an API application and get credentials — fails the "free to
  test" bar at the very first step.
- **Icecast/Shoutcast** — live broadcast-stream protocols, not personal file/library listing
  APIs; out of scope by nature, not limitation.

## MEGA — deferred, needs a feasibility spike before any Tonearm code is written

The owner wants MEGA included specifically because its SDK (`github.com/meganz/sdk`, distinct from
`github.com/meganz/webclient`, which carries a different, more restrictive license — don't confuse
the two) is genuinely **BSD-2-Clause**, no field-of-use restriction, confirmed by direct fetch of
the repo's `LICENSE` file and GitHub's repo-metadata API. That clears the licensing bar. Everything
else about it is a materially bigger lift than any `CloudDriveProvider`-shaped connector:

- **No SwiftPM or CocoaPods package exists.** MEGA's own iOS app vendors the C++/Obj-C++ SDK as a
  git submodule with a ~20-minute third-party-dependency build step (libuv, cryptopp, sqlite,
  mediainfo, etc.). Tonearm's `Package.swift` is 100% plain SPM packages today — this is a new,
  heavier dependency-management shape, and a multi-day infrastructure task on its own before any
  provider logic is written.
- **No OAuth** — direct email/password `login()`, with a separate explicit 2FA API
  (`multiFactorAuthLogin`) the app would need to detect and handle.
- **The real architectural blocker**: `RemoteLibraryProvider.resolve(node:) -> ResolvedAsset`
  needs a `URL`, and every existing provider's URL is a plain bearer/Basic-authed HTTPS URL
  straight to the provider's own servers. MEGA's end-to-end encryption means no such URL ever
  exists — the SDK instead runs an **embedded local HTTP proxy server in-process**
  (`httpServerStart`/`httpServerGetLocalLink`, gated behind `#ifdef HAVE_LIBUV` —
  **unconfirmed whether iOS builds enable this**) that decrypts chunks on the fly and serves them
  over loopback while a `MegaApi` session stays alive for the duration of playback. This can't
  reuse `CloudDriveProvider` or any existing provider pattern — it needs its own provider class
  that owns a live SDK instance and a running local server, started/stopped in step with playback
  lifecycle. CLAUDE.md's "no silent background work" rule applies directly here too: that local
  server is exactly the kind of running background process that would need a visible status/stop
  control designed into the same change, not bolted on after.
- Infuse (a real competitor) does support MEGA, so this is provably doable by someone — but
  nothing fetched confirmed *how* they handle the decryption/streaming requirement under the hood.

**Before writing `Sources/Remote/Providers/MegaProvider.swift`**: run a throwaway spike — a small
standalone Xcode project linking the vendored MEGA SDK, confirming `HAVE_LIBUV`/the local streaming
server actually works end-to-end on a real iOS device/simulator. That single fact determines
whether MEGA is buildable at all through a URL-based `resolve()`, or would need a deeper
protocol-level change to `RemoteLibraryProvider` itself (e.g. a provider that owns its own playback
pipeline instead of handing back a URL). Not started.

## Chinese cloud drives — one dead, three blocked on registration feasibility

Requested because Tonearm supports Chinese localization. Direct research (via Alist's driver docs,
which already did the real integration work for most of these and are a good proxy for "what a
third-party app actually needs," since WebSearch is unavailable in this environment) found real,
specific blockers for three of the four, and a confirmed dead end for the fourth:

- **115 Pan (115网盘) — confirmed dead, don't build.** Its official third-party Open API is
  **closed to new integrations** — Alist's own current driver docs state this outright. The only
  remaining paths are unofficial cookie-scraping (QR-code session hijack or scraping a logged-in
  client's cookie), which Alist itself flags as fragile/degrading over time, and building on it
  would be both unreliable and against the service's terms.
- **123 Pan (123云盘) — API exists, but has a confirmed dealbreaker.** File *listing* is free, but
  actual file **download** — the one feature Tonearm actually needs for playback — requires a
  paid "VIP" subscription. That fails the "free to test" bar outright regardless of anything else.
  The base account also appears to log in via a Chinese phone number, separate from the Open
  Platform's own app-registration step.
- **Aliyun Drive (阿里云盘) and Baidu NetDisk (百度网盘) — registration feasibility for a
  non-Chinese individual is a genuinely open question, not resolved by any documentation found.**
  Both have real token-based open APIs (Aliyun: OAuth-style with refresh tokens; Baidu: true OAuth
  2.0 with authorization-code/implicit/device-code modes) that would otherwise follow the same
  `CloudDriveProvider` pattern as Box/Yandex. But: Baidu's entire developer portal is
  **Chinese-only**, with no English toggle found, and its registration flow includes a "real-name
  verification" (实名认证) step; Aliyun's open-platform pages couldn't even be rendered by fetch
  (JS-heavy SPA) so registration requirements there are unverified from any primary source at all.
  Neither official doc set stated whether a non-Chinese-resident individual can actually complete
  registration — this needs a real signup attempt, not more reading.

**Prerequisite before any code is written for Aliyun Drive or Baidu NetDisk**: the owner needs to
personally attempt developer registration with each service and confirm (a) a non-Chinese identity
can complete real-name verification, (b) it doesn't require a Chinese business entity. If/when
that's confirmed, the Remote-layer work for either is the same `CloudDriveProvider`-shaped pattern
documented in `docs/plans/misty-singing-thunder.md`'s reusable checklist. 123 Pan isn't worth
pursuing further regardless, given the VIP-gated download blocker. 115 Pan is dropped.
