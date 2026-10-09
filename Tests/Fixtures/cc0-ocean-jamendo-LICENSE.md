# Extensionless MP3 conversion fixture

`cc0-ocean-jamendo.mp3` is a one-second MP3 derivative of the app's bundled
`Resources/Audio/ambient-ocean.wav` (CC0/Public Domain, see
`Sources/Audio/BuiltInContentProvider.swift`). It is not fetched from Jamendo.
Original recording: “Ocean Waves” by Nox_Sound, Freesound recording 829629.
The test copies it to a query-only URL's extensionless cache filename to reproduce
Jamendo's `format=mp32` input path, without network access or credentials.

Generated with FFmpeg/libmp3lame at 128 kbps; no Xing header, so the regression does
not depend on format inference from a tagged file.
