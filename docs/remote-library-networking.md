# Remote Library Networking

Tonearm's privacy line is: no Tonearm server, no telemetry, and network traffic only to services the user explicitly connects.

## ATS Policy

`NSAllowsArbitraryLoads` stays `false`.

`NSAllowsLocalNetworking` is `true` so user-supplied LAN music servers and NAS devices can be reached without opening arbitrary internet HTTP. Public internet services still use HTTPS under ATS. The explicit exception domains remain limited to archive.org, itunes.apple.com, and mzstatic.com because those are first-party app features, not user-supplied endpoints.

## Cloud Drives

Dropbox, Google Drive, OneDrive, and pCloud use OAuth bearer tokens stored in Keychain. Tokens are sent only to the selected provider. The cloud-drive provider layer is read-only: list folders, identify playable audio files, and resolve a stream URL for playback through the existing cache path.
