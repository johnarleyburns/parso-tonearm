# Demucs → Core ML (M6 commit 6.6) — **attempted, not landed**

The stem *pipeline* has shipped since 5.7–5.9 (chunking, overlap-add, content-addressed cache,
storage budget, the crate lane, the deck's second armed slot, the honest disabled faders). The
only missing piece is the model behind `StemModelProviding`, and this directory is the attempt
to produce it, plus **what it will take to finish** — written down so the next attempt starts
from evidence instead of from zero.

**Status: not converted.** The app ships exactly as before: `DemucsStemModel` is honestly
absent, decks play the full mix, stem faders render disabled (§36.5). That behaviour is
tested (`StemSeparatorTests`, `WorkspaceModelTests`) and is a designed state, not a
regression — the feature degrades to "unavailable", never to a silent lie.

## What was tried

Environment: `torch 2.13.0`, `coremltools 9.0`, `demucs 4.1.0`, Apple silicon.

| Step | Result |
|---|---|
| `get_model('htdemucs')` → `HTDemucs`, 41,984,456 params | works — **~84 MB at FP16**, a very reasonable ODR download |
| `torch.jit.trace` at the model's own 7.8 s segment (343,980 samples @ 44.1 kHz) | works |
| `ct.convert(traced, …)` | fails at MIL op **29 / 2087** — `aten::Int`, `TypeError: only 0-dimensional arrays can be converted to Python scalars` |
| `m.use_train_segment = False` + `torch.jit.freeze` (constant-folds the shape arithmetic) | gets to op **594 / 1732 (34%)**, then the same `aten::Int` failure |

## Why it stops, and the two ways through

The frozen graph still contains exactly one `aten::stft`, one `aten::istft`, and the
`view_as_real`/`view_as_complex` pair around them. That is the real obstacle:
**Core ML has no complex tensors**, and htdemucs is a *hybrid* model — it runs a spectral
branch and a waveform branch and sums them, with the STFT inside the network. The `aten::Int`
failures are the shape arithmetic feeding that branch.

Two viable routes, in the order I would try them:

1. **Move the STFT out of the model.** Wrap `HTDemucs` so the traced graph starts *after*
   `_spec()` and ends *before* `_ispec()`, exposing real-valued (magnitude/phase or re/im)
   spectrogram tensors as model I/O, and do the STFT/ISTFT in Swift with vDSP. The DSP is
   ordinary and the app already owns an FFT path. Cost: the `StemModelProviding` seam changes
   shape — today it passes time-domain `StemChunk`s — so `StemSeparator`'s chunking and
   overlap-add would need a spectral sibling, and the golden reconstruction test would need
   its analogue.
2. **Convert a time-domain-only model instead.** Demucs v2 (waveform U-Net) or Conv-TasNet
   have no STFT in the graph and should convert without surgery, at lower separation quality.
   The seam does not change at all. This is the cheaper path to *something working*, and the
   quality difference is audible but not disqualifying for a DJ's stem faders.

Either way the conversion must be **verified numerically against the torch reference** before
it ships, exactly as the CLAP models were (`tools/clap-coreml`, commit `42cb3fd`: audio cosine
≥ 0.9997). A stem model that converts but drifts is worse than none — it would put quiet
artefacts under a live set.

## The other thing to fix when this lands

htdemucs runs at **44.1 kHz** on 7.8 s segments; the app's pipeline chunks at 2^17 frames
(2.73 s) at **48 kHz** (`StemChunking`). Whichever model wins, the sample-rate conversion and
the segment length have to be reconciled — either resample at the seam or re-chunk to the
model's own segment. This is not a detail: getting it wrong shifts every stem against the
full mix by a few milliseconds, which is exactly the kind of error that sounds like "the
stems are a bit weird" rather than failing outright.

## Files

- `trace_htdemucs.py` — loads the pretrained model, traces and freezes it, reports parameter
  count and the ops that block conversion. Run it to reproduce the table above.
