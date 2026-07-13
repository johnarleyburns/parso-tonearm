# 01 — FLAC Streaming and Opus Playback (free tier)

## A. Multi-codec format selection

Replace the MP3-only selection with a ranked policy, keeping
`MP3AudioFormatSelector`'s accepted-format/extension/heuristic structure per
codec. New: `Core/Services/Playback/AudioFormatSelection.swift`.

```
enum AudioCodec: Int, Comparable { case flac, opus, vorbis, mp3 }

struct DerivativePolicy {
    // Ranked preference given network + cache state.
    // wifi cold:      [flac, mp3]              (instant-start streamable only)
    // cellular cold:  [mp3]                    (unless preferLosslessOnCellular)
    // prefetch/queued:[opus, flac, mp3]        (opus allowed: latency invisible)
    // cachedOpusCAF:  play the CAF, full stop.
}
```

IA format strings to accept (extend the accepted-format sets):
- FLAC: `"Flac"`, `"24bit Flac"`, extension `flac`
- Opus: `"Opus"`, extension `opus`
- Keep the existing MP3 set unchanged.

Note from `InternetArchiveService.swift:448`: items can carry per-chapter
files in MP3 + OGG + FLAC + WAV; selection must stay per-file within one
chosen format family for an item, mirroring the existing MP3-family rule, or
track counts multiply.

Settings (free): `Prefer Opus over MP3` (default on), `Prefer lossless on
cellular` (default off). Now Playing surfaces the selected codec (mockup
screen 1's signal-path readout).

## B. FLAC streaming — reuse the parsocache path

No new playback machinery. Work items:
1. Selector accepts FLAC (above).
2. `CachingResourceLoaderDelegate` content-type mapping already returns
   `org.xiph.flac`; verify the extension branch covers `.flac` filenames with
   query strings.
3. Cache sizing: FLAC files are ~6× MP3; the eviction policy and
   `StreamingCache` budget need the Pro presets story (02) but free 500 MB-ish
   default still works — it just holds fewer tracks.
4. Device test matrix: 16/44.1 and 24/96 IA derivatives, seek past prefix,
   AirPlay.

## C. Opus — Ogg→CAF remux pipeline

### Why remux (not decode)
Opus-in-CAF plays natively via AVFoundation (verified in parso-pdaudio with
ffprobe + device playback). A remux is a container swap: copy Opus packets
from Ogg pages into a CAF `data` chunk and write a `pakt` packet table. No
FFmpeg, no libopus, no re-encode, pure Swift, fully unit-testable.

### Why fetch-complete first
CAF's `pakt` chunk (mandatory for VBR codecs) needs every packet size, and the
final file length is unknown until the whole Ogg stream is scanned — Ogg has
no index. So the remuxed CAF can't be synthesized progressively for the
byte-range resource loader. The pipeline is:

```
IA .opus URL ──(existing ContiguousFileCache prefix stream OR prefetch fetch)──▶
   raw Ogg on disk (complete) ──OpusRemuxer──▶ sibling .caf ──▶
   AVPlayerItem(url: file://….caf)   [existing local-file branch]
```

`ContiguousFileCache.isComplete` (prefix == contentLength) is the trigger.
Keep the raw `.opus` only until remux succeeds, then delete it; the CAF is the
cached artifact and is what `CacheManager` accounts for.

### Components — `Core/Services/Playback/Opus/`
- `OggPageReader.swift` — page parse (capture pattern `OggS`, continuation
  flags, granule positions, segment lacing → packet reassembly), `OpusHead`
  (channels, pre-skip, input rate) parse, `OpusTags` skip. Reject chained
  streams (multiple BOS) → remux failure → fallback.
- `CAFOpusWriter.swift` — `caff` header, `desc` (kAudioFormatOpus, 48 kHz),
  `pakt` with `mNumberValidFrames`, `mPrimingFrames` = pre-skip,
  `mRemainderFrames` from last granule vs decoded total, then `data`.
- `OpusRemuxer.swift` — orchestrates reader→writer file-to-file; async,
  cancellable; ~O(file size), expected well under a second for typical tracks.

### Gapless correctness (the two traps)
1. `OpusHead` pre-skip → `pakt.mPrimingFrames`, or every Opus track starts
   with a click.
2. Final-page granule position → `mRemainderFrames`, or trailing padding
   plays as a gap.
Acceptance: decoded frame count via `AVAudioFile` equals granule-derived
count for every fixture; seam test across FLAC→Opus and Opus→Opus boundaries.

### Failure mode
Any remux error → delete partial CAF, mark Opus unavailable for that file
this session, reselect per policy (FLAC/MP3), keep playing. No user-visible
error; a local diagnostic counter only.

## D. Near-gapless transitions

Current advance is `AVPlayerItemDidPlayToEndTime` → new player. Change to:
- Maintain the queue's next item as a **preloaded** `AVPlayerItem` (its cache
  delegate attached) inserted into an `AVQueuePlayer` ~10 s before boundary.
- `PlaybackResilience` and `SessionRestoreController` observe the item swap
  rather than player teardown. `WholeItemController` semantics unchanged.
- Keep the `AVPlayerLooper` path for repeat-one exactly as is (it already
  exists and is documented as the stable approach).

Out of scope: sample-accurate gapless (needs AVAudioEngine; see decisions D4).
