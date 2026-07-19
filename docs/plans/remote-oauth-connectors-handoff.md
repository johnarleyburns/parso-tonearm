# Remote OAuth Connectors Handoff Plan

## Summary

Implement polished Pro remote-library onboarding for all nine supported connectors under the existing one-time Pro purchase.

- **Tier 1: Full guided connect**: Dropbox, Google Drive, OneDrive, pCloud, Subsonic/Navidrome, WebDAV, Jellyfin.
- **Tier 2: Advanced/manual connect**: Plex, SMB.
- Add OAuth authorization-code + PKCE sign-in for cloud providers.
- Add local Docker-backed integration tests for OAuth and all connector browse/resolve paths.
- Update README, Pro copy, add-source copy, privacy copy, and in-app How To guides so every connector is named consistently.

## Agentic Coding Handoff

Implement in small commits/phases. Do not mix broad UI polish with protocol behavior.

1. **Inventory and constants**
   - Create one source of truth for remote connector metadata: title, tier, auth type, subtitle, guide content key, `SourceKind`, and cloud provider mapping.
   - Replace duplicated connector lists in add-server UI, Pro paywall copy, privacy copy, README text references, and tests with this metadata where practical.
   - Keep all nine connectors present: Subsonic/Navidrome, WebDAV, SMB, Jellyfin, Plex, Dropbox, Google Drive, OneDrive, pCloud.

2. **OAuth core**
   - Add testable core types in `Sources/Remote`: `OAuthProviderConfig`, `OAuthPKCE`, `OAuthToken`, `OAuthTokenResponse`, `OAuthTokenStore`, and provider-specific OAuth config.
   - Keep request building and response parsing in `TonearmCore`; keep `ASWebAuthenticationSession` in app/UI code.
   - Store access token, refresh token, expiry, token type, provider account label, and pCloud API host when applicable using `CredentialStore`.
   - Refresh expired cloud tokens before browse/resolve. If refresh fails, throw a reconnect-required error surfaced by the UI.

3. **Cloud connector UX**
   - Replace manual token fields for Dropbox, Google Drive, OneDrive, and pCloud with "Sign In" flows.
   - Use PKCE and system browser auth.
   - Request read-only/minimal scopes:
     - Dropbox: file metadata/content read.
     - Google Drive: Drive readonly.
     - OneDrive: `Files.Read` plus offline access.
     - pCloud: file/list access with refresh support if available.
   - Retain injectable API/token endpoints so tests can point to the local server.

4. **Non-cloud connector UX**
   - Keep Subsonic/Navidrome, WebDAV, and Jellyfin as URL + username/password guided flows.
   - Keep Plex as URL + token, but label it Advanced and link directly to the Plex How To.
   - Keep SMB as Files-mediated folder selection, label it Advanced, and explain that the user connects SMB in Files first.

5. **How To guides**
   - Add reusable in-app guide model/view for connector setup.
   - Place guide access in `AddServerSheet` for the currently selected connector and make it reusable from Settings/Libraries later.
   - Each guide must include: prerequisites, exact fields/permissions Tonearm needs, setup steps, troubleshooting, privacy/storage notes.
   - Avoid marketing language in the guide; make it task-focused.

6. **Docs and Pro copy**
   - Update README remote-library section with Tier 1/Tier 2 connector table and setup instructions.
   - Update `ProPaywallModel` so Remote Libraries explicitly lists all nine connectors.
   - Update add-menu subtitle and privacy text so no provider is hidden behind "cloud drives."
   - Remove or fix stale README references to missing docs if still absent.

## Integration Tests

Add Docker-backed integration tests that are opt-in and deterministic.

- Add `docker-compose.remote-test.yml` and a small local fake server under test support.
- Add `make test-integration` to start the server, run integration tests, and stop the server.
- Keep normal `swift test` offline and fast.
- Gate integration tests behind an env var such as `TONEARM_REMOTE_INTEGRATION_BASE_URL`.

The fake server must emulate:

- OAuth authorize redirect, token exchange, token refresh, expired token, invalid token.
- Dropbox list + temporary link.
- Google Drive list + media download.
- OneDrive children + content.
- pCloud listfolder + getfilelink, including host handling.
- Subsonic ping/artists/artist/album/stream.
- WebDAV `PROPFIND` and authenticated file resolve.
- Jellyfin authenticate/items/stream.
- Plex sections/artists/albums/tracks/metadata/media part.
- SMB via local fixture-folder provider tests, since real iOS Files SMB cannot run in host Swift tests.

Test cases:

- OAuth PKCE verifier/challenge generation and state validation.
- Cloud OAuth exchange and refresh for Dropbox, Google Drive, OneDrive, pCloud.
- Browse root/folder or artist/album paths for all nine connectors.
- Resolve one playable audio asset for all nine connector paths.
- Verify auth headers and endpoint routing.
- Verify reconnect-required behavior on failed refresh.
- Verify Pro gating blocks connect/browse/resolve for every remote `SourceKind` when not entitled.
- Verify README/Pro metadata tests list exactly the nine supported connectors.

## Acceptance Criteria

- All nine supported connectors are listed consistently in README, Pro paywall model, add-source entry points, privacy copy, and How To guides.
- Dropbox, Google Drive, OneDrive, and pCloud no longer require users to paste raw access tokens in normal UI.
- Cloud OAuth flows use PKCE, read-only scopes where available, token refresh, and Keychain-backed persistence.
- Subsonic/Navidrome, WebDAV, Jellyfin, Plex, and SMB keep their current connection models with clearer Tier 1/Tier 2 treatment.
- Integration tests can run against a local Docker server without real third-party credentials.
- Standard unit tests remain fast and do not require Docker or network access.
- No Tonearm server, telemetry, analytics, or account system is introduced.

## Assumptions

- "Two tiers" means support/onboarding maturity inside the current Pro purchase, not separate pricing.
- OAuth is required only for Dropbox, Google Drive, OneDrive, and pCloud.
- Plex token auth and SMB through Files are acceptable Tier 2 behavior for this implementation.
- OAuth documentation references should be official provider docs only.
- No telemetry, Tonearm account, or server-side broker is introduced.
