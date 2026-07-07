# Ambient Loop Assets — bundled, offline, gapless

These WAV files ship in the app bundle. `AmbientStaticService.bundledLoopURL`
→ `PlayerViewModel.playTrack` plays the local file (no network), and PCM WAV
loops with no encoder-padding click. The Freesound HQ-mp3 preview is only a
fallback if a file is ever missing.

| File                          | Author / License | Source (Freesound)                              |
|-------------------------------|------------------|-------------------------------------------------|
| `ambient-flowing-water.wav`   | eardeer · **CC0**          | https://freesound.org/people/eardeer/sounds/443869/        |
| `ambient-rain.wav`            | speakwithanimals · **CC0** | https://freesound.org/people/speakwithanimals/sounds/525046/ |
| `ambient-ocean.wav`           | Nox_Sound · **CC0**        | https://freesound.org/people/Nox_Sound/sounds/829629/      |

**All three ambient loop sounds are CC0 (public domain)** — no attribution
is legally required (credits are still shown in-app as good practice).

### Background videos (`Resources/Video/ambient-*.mp4`)

All three are Mixkit clips under the Mixkit Free License; license compliance
for bundling in this app was verified by the project owner (2026-05-18).

## How they were produced

Freesound's public CDN only serves lossy mp3/ogg previews (the original WAV
needs an authenticated OAuth2 download). Each file here was made by decoding
the CC0 HQ-mp3 preview to PCM (removing the MP3 encoder delay/padding that
caused the loop click), capping length to ≤30 s, and applying a 0.75 s
equal-power crossfade of the tail into the head so the buffer wraps onto
itself **seamlessly** regardless of the source's own loop points. Output is
16-bit PCM stereo @ 44.1 kHz.

Regenerate with `/tmp/mkloops.py` (decode → central window → equal-power
crossfade → WAV). To shrink further, convert to CAF — the resolver prefers
`.caf` over `.wav`:

```
afconvert -f caff -d LEI16@44100 ambient-rain.wav ambient-rain.caf
```

XcodeGen bundles everything under `ParsoRadio/` automatically — no project
edits needed.
