# Stems — converting htdemucs and landing real separation

**Goal, in one sentence:** the four stem faders on a deck move real separated audio, produced by
a Core ML model that has been proved numerically identical to the PyTorch reference, without
changing the shape of the `StemModelProviding` seam.

**Status when this plan was written (2026-08-15):** the conversion **works**. It was run, it
produced an `.mlpackage`, and its outputs match torch to `max|d| 1.1e-6`. What remains is Swift
work, packaging and verification — no research. Everything below is written so an agent with no
prior context can execute it end to end.

---

## 1 · Read this first: the previous notes were wrong

`tools/demucs-coreml/README.md` (commit 6.6) says conversion is blocked because "Core ML has no
complex tensors" and that the fix is architectural. **That diagnosis is incorrect and the file
must be replaced as part of task S1.** The evidence:

- coremltools 9.0's Torch frontend registers `stft`, `complex`, `real`, `imag`, `view_as_real`.
  Verify yourself:
  ```python
  from coremltools.converters.mil.frontend.torch.ops import _TORCH_OPS_REGISTRY as R
  n = list(R.name_to_func_mapping.keys())
  [x for x in n if any(s in x for s in ('stft','fft','complex','view_as','real','imag'))]
  ```
  It does **not** register `istft` or `view_as_complex`. Those two ops — and only those two —
  have to leave the graph.
- The `aten::Int` failure at MIL op 594 that the README attributes to the STFT is a
  **coremltools bug under NumPy 2**. `_cast` in
  `coremltools/converters/mil/frontend/torch/ops.py` does `dtype(x.val)` where `x.val` is
  `np.array([N])`, and NumPy 2 raises *"only 0-dimensional arrays can be converted to Python
  scalars"*. All 36 `aten::Int` sites in the graph are the same bug. A five-line patch clears
  every one of them.
- The old attempt could never have succeeded anyway: the venv was **Python 3.14**, for which
  coremltools ships no compiled extension. `libcoremlpython` and `libmilstoragepython` both
  failed to import, so `mlprogram` serialization and `predict` were impossible regardless of
  the graph. Use **Python 3.12**.

Four walls were hit, in this order, and all four are cleared:

| # | Wall | Cause | Fix |
|---|---|---|---|
| 1 | `aten::Int`, op 594 | coremltools `_cast` + NumPy 2 | patch `_cast` (below) |
| 2 | `slice_by_index` rejects `tensor[...,complex64]` | Core ML has complex as a *type* but almost no MIL op accepts it | lift STFT out to Swift |
| 3 | `_native_multi_head_attention` not implemented | PyTorch's fused attention fast path | `torch.backends.mha.set_fastpath_enabled(False)` |
| 4 | `spec` output all `NaN`, waveform wrong | **FP16 overflow**, not a graph error | convert at `FLOAT32` |

---

## 2 · What is already true (do not rebuild it)

Shipped and tested since M5 5.7–5.9. None of it needs redesign:

- `Sources/DJ/Stems/StemModel.swift` — `StemKind`, `StemChunk`, `StemSeparation`,
  `StemModelError`, the `StemModelProviding` protocol, and `DemucsStemModel` (the honest shell
  that throws `.conversionPending`).
- `Sources/DJ/Stems/StemSeparator.swift` — `StemChunking` (periodic-Hann COLA kernel, proven
  exact at 50% overlap) and `StemSeparator` (chunk → model → window → overlap-add).
- `Sources/DJ/Stems/StemCache.swift` — content-addressed four-`.caf`-per-track cache, versioned
  by `AnalysisVersions.stems`, invalidated on model upgrade (§36.4).
- `Sources/DJ/Stems/StemService.swift` — the crate lane, storage budget, governor fence,
  `separateOnDemand`.
- `Sources/DJ/Engine/StemVoices.swift` — the deck's armed second slot; a deck with no stem set
  is byte-for-byte the current reader.
- `Sources/DJ/Semantic/ModelResourceService.swift` — `ModelTag.stems = "demucs-stems"` and the
  `NSBundleResourceRequest` ODR delivery, already used by the CLAP encoders.
- The honest-absence behaviour: model absent → `separate` returns nil → deck plays the full mix
  → faders render disabled (§36.5). Locked by `StemSeparatorTests` and `WorkspaceModelTests`.
  **Do not weaken these tests. They are the fallback that keeps a failed separation from
  becoming a silent lie (ADR-10).**

The precedent to follow for everything about *how* a model ships is `tools/clap-coreml`
(commit `9f42cf5`): a reproducible script, a numeric verification against the torch reference
(audio cosine ≥ 0.9997), an ODR tag, and a version stamp.

---

## 3 · Decisions taken up front

1. **Convert `htdemucs`, not a lesser model.** It converts. There is no reason to accept
   Demucs v2 / Conv-TasNet quality now that the blockers are known to be mundane.
2. **Both transforms live in Swift.** The Core ML model takes `(mag, audio)` and returns
   `(spec, waveform)`. Core ML's complex support is too thin to keep the STFT inside, and there
   is no `istft` at all.
3. **The `StemModelProviding` seam keeps its time-domain shape.** `separate(chunk:) ->
   StemSeparation?` stays exactly as it is. The wrapper owns STFT, Core ML, ISTFT and the sum.
   The previous README claimed the seam must grow a spectral sibling — it must not, and doing so
   would force `StemSeparator`'s chunking and the golden reconstruction test to fork.
4. **FP32 weights.** ~168 MB over ODR rather than ~84 MB. FP16 produces `NaN` in the spectral
   branch. Selective FP16 (keeping only the overflowing ops in FP32) is a **later size
   optimisation, explicitly out of scope for the first landing** — and must not be attempted
   without re-running the full numeric verification.
5. **Run the model at its own rate and segment (44 100 Hz, 343 980 frames).** Resample the whole
   track once at the separator, not per chunk. Quality follows the training geometry and the
   verification in §5 is valid at exactly that geometry.
6. **Verification gate: `max|d| ≤ 1e-4` against saved torch reference tensors, per output.**
   The measured value is `1.1e-6`; 1e-4 is a generous ceiling that still catches a real
   regression. **Do not use cosine similarity as the gate** — summing 11M float32 products
   accumulates enough error to print values above 1.0, which is how the first run produced the
   nonsense figure `cosine 1.008`. `max|d|` relative to output RMS is the honest measure.
7. **No end-to-end STFT round-trip identity test.** Demucs's analysis/synthesis pair is *not*
   invertible: `_spec` drops the Nyquist bin (`[..., :-1, :]`) and trims two frames each end
   (`[..., 2:2+le]`), and `_ispec` zero-fills them back. Measured round-trip error on
   unit-variance noise is **1.54**, not ~0. The only valid Swift tests are golden-vector
   comparisons against saved torch tensors for each transform separately.

---

## 4 · The conversion, verbatim

Task S1 is to save this as `tools/demucs-coreml/convert_htdemucs.py`, replacing the incorrect
README. It has been run and it works.

**Environment** (the old `demucs-venv` is Python 3.14 and is unusable — delete any reference):

```sh
uv venv --python 3.12 .venv-demucs
VIRTUAL_ENV=$PWD/.venv-demucs uv pip install "torch==2.7.*" "coremltools>=9.0" demucs numpy
```

```python
#!/usr/bin/env python3
"""Convert htdemucs to Core ML with both transforms lifted into Swift.

Core ML has complex tensors as a type but almost no MIL op accepts them
(slice_by_index does not), and it has no istft at all. So the model takes the
real spectrogram and the raw waveform, and returns the real masked spectrogram
and the waveform branch; Swift owns STFT and ISTFT.

Outputs, next to this script:
  HTDemucsCore.mlpackage   the converted model (FP32)
  reference.pt            torch reference tensors for the Swift golden tests
"""
import warnings
warnings.filterwarnings("ignore")
import pathlib
import numpy as np
import torch
import torch.nn as nn

import coremltools as ct
from coremltools.converters.mil.frontend.torch import ops as tops
from coremltools.converters.mil import Builder as mb

HERE = pathlib.Path(__file__).parent


def _cast_patched(context, node, dtype, dtype_name):
    """coremltools' own _cast does dtype(np.array([N])); NumPy 2 rejects that.

    This is the entire cause of the `aten::Int` failure that earlier notes
    blamed on complex tensors. All 36 sites in the htdemucs graph are this bug.
    """
    inputs = tops._get_inputs(context, node, expected=1)
    x = inputs[0]
    if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
        raise ValueError("input to cast must be either a scalar or a length 1 tensor")
    if x.can_be_folded_to_const():
        val = x.val
        if isinstance(val, np.ndarray) and val.size == 1:
            val = val.reshape(()).item()
        res = mb.const(val=dtype(val), name=node.name)
    elif len(x.shape) > 0:
        squeezed = mb.squeeze(x=x, name=node.name + "_item")
        res = mb.cast(x=squeezed, dtype=dtype_name, name=node.name)
    else:
        res = mb.cast(x=x, dtype=dtype_name, name=node.name)
    context.add(res, node.name)


tops._cast = _cast_patched

# nn.MultiheadAttention traces into the fused _native_multi_head_attention op,
# which no converter implements. The unfused path is numerically identical.
torch.backends.mha.set_fastpath_enabled(False)

from demucs.pretrained import get_model


class Core(nn.Module):
    """htdemucs with both transforms lifted out: (mag, mix) -> (spec, xt).

    `_spec`/`_magnitude` are replaced by the caller-supplied real spectrogram,
    and `_mask`/`_ispec` are cut so no complex op reaches the graph. Everything
    between — encoders, cross-transformer, decoders, the normalisation and its
    inverse — is untouched, which is why the outputs match torch exactly.
    """

    def __init__(self, model):
        super().__init__()
        self.model = model
        self.stash = {}

    def forward(self, mag, mix):
        m, stash = self.model, self.stash
        saved = (m._spec, m._magnitude, m._mask, m._ispec)
        m._spec = lambda x: None                      # z is unused downstream in cac mode
        m._magnitude = lambda z: mag
        m._mask = lambda z, x: (stash.__setitem__("spec", x), x)[1]
        m._ispec = lambda z, length=None, scale=0: torch.zeros(
            mag.shape[0], 4, m.audio_channels, length, dtype=mag.dtype, device=mag.device)
        try:
            xt = m(mix)
        finally:
            m._spec, m._magnitude, m._mask, m._ispec = saved
        return stash["spec"], xt


def main():
    bag = get_model("htdemucs")
    model = (bag.models[0] if hasattr(bag, "models") else bag).eval()
    model.use_train_segment = False
    seg = int(model.segment * model.samplerate)     # 343980
    print(f"sources={model.sources} sr={model.samplerate} nfft={model.nfft} "
          f"hop={model.hop_length} segment={seg}")

    torch.manual_seed(0)
    audio = torch.randn(1, model.audio_channels, seg) * 0.1

    with torch.no_grad():
        z = model._spec(audio)                      # complex64 [1, 2, 2048, 336]
        mag = model._magnitude(z)                   # real      [1, 4, 2048, 336]

    core = Core(model).eval()
    with torch.no_grad():
        ref_spec, ref_xt = core(mag, audio)
        traced = torch.jit.freeze(torch.jit.trace(core, (mag, audio), check_trace=False))

    kinds = {}
    for n in traced.graph.nodes():
        kinds[n.kind()] = kinds.get(n.kind(), 0) + 1
    bad = {k: v for k, v in kinds.items()
           if any(s in k for s in ("stft", "complex", "view_as"))}
    assert not bad, f"complex-domain ops still in graph: {bad}"

    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mag", shape=tuple(mag.shape), dtype=np.float32),
                ct.TensorType(name="audio", shape=tuple(audio.shape), dtype=np.float32)],
        outputs=[ct.TensorType(name="spec"), ct.TensorType(name="waveform")],
        minimum_deployment_target=ct.target.iOS18,
        # FLOAT16 produces NaN in the spectral branch. Do not change without
        # re-running the verification below.
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram")
    ml.save(str(HERE / "HTDemucsCore.mlpackage"))

    out = ml.predict({"mag": mag.numpy().astype(np.float32),
                      "audio": audio.numpy().astype(np.float32)})
    ok = True
    for name, ref in (("spec", ref_spec), ("waveform", ref_xt)):
        got = torch.from_numpy(np.asarray(out[name], dtype=np.float32)).reshape(ref.shape)
        d = (got - ref).abs().max().item()
        rms = ref.pow(2).mean().sqrt().item()
        print(f"{name}: max|d| {d:.3e}  rms {rms:.3e}  -> {'PASS' if d <= 1e-4 else 'FAIL'}")
        ok &= d <= 1e-4
    if not ok:
        raise SystemExit("numeric verification failed")

    # Golden vectors for the Swift transform tests (task S2).
    torch.save({"audio": audio, "mag": mag, "spec": ref_spec, "xt": ref_xt,
                "ispec": model._ispec(model._mask(None, ref_spec), seg)},
               HERE / "reference.pt")
    print("saved HTDemucsCore.mlpackage + reference.pt")


if __name__ == "__main__":
    main()
```

**Measured result of running exactly this:**

```
spec:     max|d| 1.11e-06   (rms 1.94e-02)   PASS
waveform: max|d| 1.19e-07   (rms 1.88e-02)   PASS
```

---

## 5 · The transform contract Swift must reproduce

Every number here was read out of `demucs 4.1.0` and confirmed by running it. Do not re-derive
them; do not "clean them up".

### 5.1 Constants

| Name | Value |
|---|---|
| model sample rate | **44 100 Hz** |
| segment | `39/5 s` → **343 980 frames** |
| `nfft` | **4096** |
| `hop_length` | **1024** (`= nfft // 4`; `_spec` asserts this) |
| window | `torch.hann_window(4096)` — **periodic** Hann, `win_length = 4096` |
| `normalized` | **`True`** — torch divides the forward transform by `sqrt(4096) = 64` and the inverse multiplies by it |
| `center` | **`True`** — torch pads `nfft // 2 = 2048` each side, `pad_mode='reflect'`, *inside* `torch.stft` |
| audio channels | 2 |
| **sources order** | **`['drums', 'bass', 'other', 'vocals']`** |

> **The source order is not `StemKind.allCases` order.** `StemKind` is
> `vocals, drums, bass, other` (indices 0–3). The model's `S` axis is
> `drums=0, bass=1, other=2, vocals=3`. Mapping these straight across silently swaps every
> stem — the vocal fader would mute the drums. Write the mapping table once, in one place, and
> unit-test it by name.

### 5.2 Forward: `_spec` then `_magnitude`

Input `x` is `[1, 2, 343980]` at 44 100 Hz.

1. `le = ceil(343980 / 1024) = 336`
2. `pad = (1024 // 2) * 3 = 1536`
3. reflect-pad `x` by `(1536, 1536 + 336*1024 - 343980)` = **`(1536, 1620)`** → length **347 136**
   - demucs uses `pad1d`, which inserts extra zero padding first only when the signal is
     shorter than the padding. At this length that branch never fires — plain reflect.
4. `torch.stft(nfft=4096, hop=1024, window=hann(4096), win_length=4096, normalized=True,
   center=True, return_complex=True, pad_mode='reflect')` → `[2, 2049, 340]` complex
5. drop the Nyquist bin: `[..., :-1, :]` → `2048` bins
6. trim two frames each end: `[..., 2 : 2+336]` → `[1, 2, 2048, 336]` complex
7. `_magnitude` with `cac=True`:
   `view_as_real(z)` → `[1,2,2048,336,2]`; `.permute(0,1,4,2,3)` → `[1,2,2,2048,336]`;
   `.reshape(1, 4, 2048, 336)`.
   **Channel layout is `[L.re, L.im, R.re, R.im]`** — channel-major, re/im minor
   (`index = channel*2 + reim`).

Result: **`mag` = `[1, 4, 2048, 336]` float32.** This is the model's `mag` input.

### 5.3 Inverse: `_mask` then `_ispec`

Model output `spec` is `[1, 4, 4, 2048, 336]` = `[batch, source, channel*2, freq, frame]`,
already denormalised by the model (the mean/std restore happens inside `forward`, before
`_mask`). Swift does **no** normalisation.

1. unpack cac: `view(1,4,2,2,2048,336).permute(0,1,2,4,5,3)` → complex `[1,4,2,2048,336]`
   — i.e. for source `s`, channel `c`: `re = spec[0,s,c*2,f,t]`, `im = spec[0,s,c*2+1,f,t]`
2. pad the frequency axis by 1 at the end (restore the Nyquist bin as zero) → 2049 bins
3. pad the time axis by 2 at each end (zeros) → 340 frames
4. `le = 1024 * ceil(343980/1024) + 2*1536 = 344064 + 3072 = **347136**`
5. `torch.istft(nfft=4096, hop=1024, window=hann(4096), win_length=4096, normalized=True,
   length=347136, center=True)`
6. trim: `x[..., 1536 : 1536 + 343980]`

### 5.4 The sum

`voice[s] = ispec_result[s] + waveform[s]`, where `waveform` is the model's second output,
`[1, 4, 2, 343980]`, already denormalised. Then map `s` through the order table in §5.1.

### 5.5 A warning about the existing FFT code

`Sources/DJ/Analysis/STFT.swift` (`STFTKernel`) **cannot be reused.** It computes a *power*
spectrum (`vDSP_zvmags`), discards phase, has no inverse, uses `vDSP_HANN_NORM` (energy-
normalised, not the periodic Hann demucs uses), and defaults to a 2048 hop at 48 kHz. Write a
new kernel; do not extend this one, and do not change it — the analysis pipeline depends on its
current behaviour.

`vDSP.FFT<DSPSplitComplex>` with `log2n = 12` is the right primitive. The forward is the
standard real-FFT idiom already demonstrated in `STFTKernel.spectrum`; note that vDSP's real
FFT returns the result **scaled by 2** relative to the mathematical DFT and packs Nyquist into
`imagp[0]` — both must be corrected before comparing with torch. Get the golden test in §6.2
passing on a **single frame** before writing anything else.

---

## 6 · Commit sequence

One task per commit, on `main`, each landing with its tests. Do not batch. Set the `git commit`
timeout to **at least 300 s** — the pre-commit hook runs the full local suite including
simulator tests.

### S1 — the conversion script and its evidence

- Write `tools/demucs-coreml/convert_htdemucs.py` (§4 verbatim).
- **Replace** `tools/demucs-coreml/README.md`. The current text asserts a root cause that is
  false; leaving it would send the next reader down the wrong path. The new README states the
  four walls of §1, the environment, the measured numbers, and the FP16 caveat.
- Delete `tools/demucs-coreml/trace_htdemucs.py` — it exists only to reproduce a wrong
  conclusion.
- **Do not commit the `.mlpackage` or `reference.pt`.** They are build outputs, ~168 MB and
  ~200 MB. Add `tools/demucs-coreml/*.mlpackage` and `tools/demucs-coreml/reference.pt` to
  `.gitignore`.
- Gate: running the script on a clean 3.12 venv prints two `PASS` lines.

### S2 — the Swift STFT/ISTFT kernel

- New file `Sources/DJ/Stems/StemSpectrogram.swift`. Pure, `Sendable`, no Core ML import, no
  engine dependency — it must be testable in `swift test` with no model present.
- API shape:
  ```swift
  public struct DemucsSpectrogram: Sendable {
      public static let sampleRate: Double = 44_100
      public static let segmentFrames = 343_980
      public static let nfft = 4096
      public static let hop = 1024
      public static let bins = 2048        // Nyquist bin dropped
      public static let frames = 336

      /// [L.re, L.im, R.re, R.im] planar, each `bins * frames`, row-major (freq, frame).
      public static func forward(left: [Float], right: [Float]) -> [Float]
      /// Inverse of `forward`'s layout for one source; returns `segmentFrames` per channel.
      public static func inverse(spec: UnsafeBufferPointer<Float>) -> (left: [Float], right: [Float])
  }
  ```
- Tests — `Tests/DJTests/StemSpectrogramTests.swift`:
  1. **Golden forward.** Compare against `mag` from `reference.pt`, `max|d| ≤ 1e-4`.
  2. **Golden inverse.** Compare against `ispec` from `reference.pt`, `max|d| ≤ 1e-4`.
  3. Window is periodic Hann: `w[0] == 0`, `w[nfft/2] == 1`, `w[i] == w[nfft-i]` for `i>0`.
  4. Output shape and layout: index `c*2+ri` carries the channel/part the docs claim.
  - Export the two golden tensors from `reference.pt` to a compact binary fixture under
    `Tests/DJTests/Fixtures/` — **not** the whole `.pt`. `mag` is 2.75M floats (11 MB); store
    it as float16 or subsample a deterministic slice (e.g. every 97th element with its index)
    and compare on that slice. A multi-megabyte fixture in the repo is not acceptable; state
    the subsampling rule in the test so it is reproducible from `reference.pt`.
- Gate: `swift test` green; the two golden tests fail loudly if the kernel drifts.

### S3 — fix the separator's memory profile before it can ever run

**This is a live bug that no test has caught, because the model has never been present.**
`StemSeparator.separate` (`Sources/DJ/Stems/StemSeparator.swift:157–201`) accumulates
`vocalsL/vocalsR/drumsL/...` as `[[Float]]` — every chunk output for all four voices and both
channels — and only overlap-adds at the end. At 50% overlap that is **~2× the track length ×
8 channels** held at once: for a five-minute track, roughly **900 MB**. The moment stems
actually work, this will be the first thing that kills the app, and `MemoryCeiling` will shed
the lane rather than report the real cause.

- Rewrite `separate` to overlap-add **incrementally**: allocate the eight full-length output
  buffers once, and `vDSP_vmul` + `vDSP_vadd` each chunk into place as it comes back from the
  model. Peak extra memory becomes one chunk, not the whole track.
- Keep `StemChunking.overlapAdd` — it is correct and tested. Add a streaming sibling
  (`overlapAddInto(_:chunk:window:offset:)`) rather than replacing it, so the existing COLA
  golden test still covers the kernel.
- Tests: the existing reconstruction-golden test must still pass unchanged, plus a new test
  that a 10-chunk separation allocates no per-chunk accumulator (assert on the streaming API's
  behaviour, e.g. reconstruct identically from a passthrough model).
- Gate: `swift test` green; reconstruction still exact.

### S4 — model-native geometry at the seam

The app chunks at **131 072 frames @ 48 kHz** (2.73 s); the model wants **343 980 @ 44.1 kHz**
(7.8 s). Resample **once per track**, not per chunk.

- Add to `StemModelProviding` (additive, the method signature does not change):
  ```swift
  /// The rate and segment the model was trained at. The separator resamples the
  /// track to this rate once, chunks at this length, and resamples the voices back.
  var nativeSampleRate: Double { get }
  var segmentFrames: Int { get }
  ```
  Give both a default implementation returning `StemChunking.workingSampleRate` and
  `StemChunking.chunkFrames`, so existing fakes in tests compile untouched.
- `StemSeparator.separate(pcm:)`: resample `pcm` 48 000 → `nativeSampleRate` once; chunk at
  `segmentFrames` with 50 % overlap (`hop = segmentFrames / 2 = 171 990`); run; overlap-add;
  resample the four voices back to 48 000 once. The cache keeps writing 48 kHz `.caf`, so
  `StemCache`, `StemVoices` and the deck reader are **untouched**.
- Use `AVAudioConverter` for the rate conversion, and assert the round-trip length is what the
  arithmetic says — an off-by-a-few-hundred-samples drift here shifts every stem against the
  full mix by milliseconds, which sounds like "the stems are a bit weird" rather than failing.
- Tests: `StemSeparatorTests` gains a case where the fake model declares 44 100/343 980 and the
  separator returns voices at 48 000 with the input's frame count, ±0 frames.
- Gate: `swift test` green; existing tests unchanged.

### S5 — wire `DemucsStemModel` to Core ML

- `Sources/DJ/Stems/StemModel.swift`: replace the `conversionPending` throw in
  `DemucsStemModel.separate(chunk:)` with the real path:
  1. `MLModel(contentsOf:)` the ODR-delivered `.mlpackage`, loaded **once** and held; a
     per-chunk load is the classic performance bug and will dominate the runtime.
  2. `DemucsSpectrogram.forward` → `MLMultiArray` for `mag`; the chunk's PCM → `MLMultiArray`
     for `audio`.
  3. `prediction` → `spec`, `waveform`.
  4. `DemucsSpectrogram.inverse` per source, add `waveform`, map the source order (§5.1).
  5. Return `StemSeparation` in `StemKind` order.
- `nativeSampleRate = 44_100`, `segmentFrames = 343_980`.
- Keep `.conversionPending` in `StemModelError` — it is still the right state for a
  present-but-unloadable package, and dropping it would turn a broken download into a silent
  passthrough. Add `.modelLoadFailed` detail carrying the underlying `MLModel` error.
- **Bump `AnalysisVersions.stems`.** This is what invalidates every `stem_cache` row written by
  a previous model version (§36.4). Forgetting it means a user who had cached silence keeps it.
- Set `MLModelConfiguration.computeUnits = .all` and record in a comment that the ANE path is
  the one that matters; measure before choosing anything narrower.
- Tests: `Tests/DJTests/DemucsStemModelTests.swift` — model absent → `isAvailable() == false`
  and `separate` returns nil (**the existing honest-absence behaviour, re-asserted**); a
  corrupt package → `.modelLoadFailed`, never nil; the source-order mapping table by name.
  These run without the model present, which is the normal CI state.
- Gate: `swift test` green with and without the package.

### S6 — ODR packaging

- Follow `tools/clap-coreml`'s precedent exactly. Tag `demucs-stems`, file name
  `DemucsStems.mlpackage` (the name `DemucsStemModel` already expects).
- Add the resource to the Xcode project **through `project.yml`**, then run `xcodegen generate`
  and **commit the regenerated `Tonearm.xcodeproj/project.pbxproj`** (decision 25 — the repo
  commits the generated project).
- Confirm the ODR tag downloads on first use and that the failure path (no network, tag
  unavailable) still yields honest absence rather than a hang.
- Gate: app builds; a device/simulator run shows the tag fetching and `isAvailable()` flipping.

### S7 — device measurement, and the honest ceiling

Nothing before this point tells you whether stems are *usable*. Measure, then decide.

- Time one 343 980-frame segment on a real device (`.all` compute units). A five-minute track is
  ~46 segments at 50 % overlap. Record segments/second and total track time.
- Measure peak footprint during a separation against `MemoryCeiling`'s per-device-class ceiling.
  Working set per segment is roughly: `mag` 11 MB + `spec` 44 MB + `waveform` 11 MB + model
  weights ~168 MB.
- **If a device class cannot run it inside the ceiling, that device class reports stems
  unavailable.** That is a supported, already-tested state — it is not a reason to ship a model
  that gets shed mid-set. Wire the decision into `StorageBudgetService`/`MemoryCeiling`'s
  existing device-class split, and say so in the UI.
- Gate: numbers written into `current_status.md`; the governor's `.stems` lane exercised.

### S8 — UI truth-up and regression coverage

- `Sources/DJ/Features/Workspace/SoloDeckView.swift:589` hardcodes the string
  **`"unavailable · M5"`** next to the stem faders. It must become the real
  `DeckStemStatus` (`unavailable` / `separating` / `prepared`). Grep for other hardcoded stem
  copy before assuming this is the only one.
- Extend the `djhw` lane (or add `djstem`) in `UIRegressionTests/`: load a track into a crate,
  run separation, assert the faders become enabled and that moving the vocal fader changes the
  recorded audio. The acoustic assertion belongs in `scripts/ui-regression/verify-mix.py` and
  should follow the existing §53.9 pattern — measure a band before and after the gesture on the
  **settled** state, using `span_starts`/`band_level`, not a mid-flight window.
- The lane must **skip with a stated reason** when the ODR tag is absent, never fake a pass
  (§53.4).
- **Do not wire any of this into CI or a git hook.** CI runs `swift test` only; the UI
  regression suite is hand-run before a release and lives in its own target/scheme
  (`TonearmUIRegressionTests` / `TonearmUIRegression`).
- Gate: `LANES=djmix` still green; the new lane green or honestly skipped.

---

## 7 · Licensing and attribution

`demucs` is MIT-licensed and the pretrained `htdemucs` weights ship under that licence. Record
the attribution where the app already records third-party model attribution (the CLAP encoders
set the precedent) and in the App Store "third-party content" notes. Confirm before shipping —
this is a five-minute check that is expensive to get wrong after release.

---

## 8 · Risks, ranked

1. **Device runtime makes it unusable.** A 42M-parameter transformer over 7.8 s segments may be
   too slow on older hardware. Mitigation is S7: measure, and let a device class say
   "unavailable" honestly. Do not discover this in a tester's hands.
2. **The source-order swap.** Silent, plausible, and catastrophic — the faders would all work
   and all be wrong. Mitigated by the named test in S5.
3. **Resampling drift.** A few hundred samples of offset is inaudible as an error and audible as
   "off". Mitigated by the exact-length assertion in S4.
4. **The 168 MB download.** Acceptable over ODR, but confirm the app's first-run experience does
   not block on it. Selective FP16 is the mitigation if it proves too large — after S7, never
   before, and always with the full numeric verification re-run.
5. **FP16 temptation.** Someone will try it for the size win. The `NaN` is in the spectral
   branch and will not show up in a smoke test — it will show up as silence or noise under a
   live set. The verification gate in S1 is what stops this; keep it in the script.

---

## 9 · Definition of done

- `tools/demucs-coreml/convert_htdemucs.py` runs clean on a fresh 3.12 venv, printing two
  `PASS` lines.
- `swift test` green, including the two golden transform tests and the source-order test.
- A track separated on a device produces four voices that sound like their names, and the
  vocal fader mutes the vocal.
- Peak footprint measured and inside the ceiling for every device class that reports stems
  available; classes that cannot are honestly `unavailable`.
- The `"unavailable · M5"` string is gone.
- `LANES=djmix` still green; the stem lane green or honestly skipped with its remedy.
- `current_status.md` updated with the measured numbers.
