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

## Provider coverage research (survey done, nothing built yet)

A background research pass (prompted by "I want to basically support every free library in
existence... favor oauth-supporting ones") surveyed what competitor apps (Infuse, Symfonium,
doubleTwist, VOX, CloudBeats) connect to and checked each candidate against Tonearm's actual
`CloudDriveAPI.Provider`/`OAuthCore` shape (`Sources/Remote/Providers/CloudDriveAPI.swift`,
`CloudDriveProvider.swift`, `OAuthCore.swift`) — currently Dropbox/Google Drive/OneDrive/pCloud,
each just a provider-enum case + two endpoint cases (`list`, `resolveFile`) + an
`OAuthProviderConfig`. Ranked by effort-to-value:

1. **Box — build this first.** Real OAuth 2.0 authorization-code flow, workable free personal
   tier, generous rate limits, and a straight 5th case in the existing `CloudDriveProvider`
   pattern (`GET /folders/{id}/items`, `GET /files/{id}/content`). Both Infuse and Symfonium
   support it already. Lowest-cost, highest-confidence add on this list.
2. **Verify Ampache and Funkwhale against the existing `SubsonicProvider` — likely zero new
   code.** Both are free, open-source, self-hostable, and both document Subsonic-API
   compatibility modes. Needs a live-instance verification pass (spin up a test server, point
   Tonearm's Subsonic connector at it), not a new provider class — same shape of win as Nextcloud
   below.
3. **Emby — new provider class, but mirrors `JellyfinProvider` closely.** Username/password
   session or static API key, essentially the same shape Jellyfin already speaks (Jellyfin
   historically forked from Emby). Emby Premiere gates specific client features (Live TV/DVR,
   hardware transcoding) per Emby's own materials, but core library/API access for testing was
   not found gated — confirm that boundary against a live free server before shipping.
4. **Yandex.Disk — technically trivial, ask the owner first.** Clears every technical bar (OAuth
   2.0, REST API, free consumer tier) and would be another straight `CloudDriveProvider` case,
   but it's a Russian company's consumer product — App Store review risk, sanctions/payment-
   processor exposure, and a shrinking non-Russian user base make this a product/legal decision,
   not an engineering one. Infuse supports it, so there's real demand, but don't build it as part
   of a routine "add another cloud drive" batch.
5. **Nextcloud/ownCloud — confirm, don't build.** Standard WebDAV (RFC 4918); Tonearm's existing
   generic `WebDAVProvider` should already reach these servers with no new code. At most needs a
   UI label/preset for discoverability. Documentation/marketing item, not an engineering task.

**Defer until specific demand:**
- **Synology** — NAS devices already expose standard SMB/WebDAV, both already supported; a
  bespoke DSM/Synology Drive API would be new infrastructure for marginal gain over what's
  already there.
- **Koofr** — real 10GB-free tier, but no public REST/OAuth API docs could be found (dev-docs
  paths 404'd). A maybe, not a yes, until someone finds live API docs.
- **MEGA** — real free tier and real competitor demand (Infuse), but its "API" is a client-side-
  encryption SDK (crypto/key management), not a bearer-token REST surface — genuinely new
  infrastructure, not a drop-in `CloudDriveProvider` case.

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
- **Region-specific Chinese cloud drives** (Aliyun Drive, 123 Drive, 115 Drive, Baidu NetDisk) —
  skipped deliberately: mostly Chinese-language docs, uncertain OAuth/App-Review friction,
  negligible addressable Tonearm user base relative to integration cost.

**Recommended build order whenever this is picked up:** Box first (cheapest, most confident),
then spend an afternoon verifying Ampache/Funkwhale against the existing Subsonic connector
(near-zero cost if confirmed), then Emby as the next real engineering task. Raise Yandex.Disk
with the owner explicitly before building it, regardless of how technically easy it is.
