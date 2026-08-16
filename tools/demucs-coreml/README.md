# Demucs → Core ML (stems, M6/plan `dj-stems-model.md` S1)

The htdemucs → Core ML conversion **works** and is numerically verified to match
the PyTorch reference. This directory is that conversion: a reproducible script,
the reference tensors it produces, and the evidence. Earlier notes here
(`trace_htdemucs.py`, the "attempted, not landed" README) diagnosed the blockers
as architectural — **that diagnosis was wrong**, and this README replaces it.

## Status

- `convert_htdemucs.py` converts `htdemucs` to an FP32 `mlprogram` with both
  transforms (STFT/ISTFT) lifted out into Swift, and verifies the Core ML
  outputs against the traced torch model per output with `max|d| ≤ 1e-4`.
- Measured result of running it (Python 3.12, `torch 2.7.*`, `coremltools ≥ 9.0`,
  `demucs 4.1.0`):

  ```
  spec:     max|d| 1.11e-06   (rms 1.94e-02)   PASS
  waveform: max|d| 1.19e-07   (rms 1.88e-02)   PASS
  ```

- The artifacts — `HTDemucsCore.mlpackage` (~168 MB FP32) and `reference.pt`
  (~200 MB) — are build outputs and are **gitignored**. Do not commit them.

## The four walls, in the order they were hit, all cleared

| # | Wall | Cause | Fix |
|---|---|---|---|
| 1 | `aten::Int`, op 594 | coremltools `_cast` does `dtype(np.array([N]))`; NumPy 2 rejects that | patch `_cast` (in the script below) |
| 2 | `slice_by_index` rejects `tensor[...,complex64]` | Core ML has complex as a *type* but almost no MIL op accepts it | lift STFT out to Swift |
| 3 | `_native_multi_head_attention` not implemented | PyTorch's fused attention fast path | `torch.backends.mha.set_fastpath_enabled(False)` |
| 4 | `spec` output all `NaN`, waveform wrong | **FP16 overflow**, not a graph error | convert at `FLOAT32` |

Earlier notes blamed the `aten::Int` failure on complex tensors. The graph *does*
hold `stft`/`complex`/`real`/`imag`/`view_as_real` (coremltools 9's Torch frontend
registers those), but **not** `istft` or `view_as_complex`. Those two ops — and
only those two — have to leave the graph. The model therefore takes the caller's
real spectrogram `(mag)` and the raw waveform `(audio)` and returns the real
masked spectrogram `(spec)` and the waveform branch `(waveform)`; Swift owns
STFT and ISTFT (`DemucsSpectrogram` in `Sources/DJ/Stems/`).

## Environment (the old `demucs-venv` was Python 3.14 and is unusable — delete any reference)

```sh
uv venv --python 3.12 .venv-demucs
VIRTUAL_ENV=$PWD/.venv-demucs uv pip install "torch==2.7.*" "coremltools>=9.0" demucs numpy
VIRTUAL_ENV=$PWD/.venv-demucs .venv-demucs/bin/python tools/demucs-coreml/convert_htdemucs.py
```

Gate: the run prints two `PASS` lines (above) and writes
`HTDemucsCore.mlpackage` + `reference.pt` next to this script.

## The FP16 caveat

The model is converted at **FLOAT32**. `FLOAT16` produces `NaN` in the spectral
branch — the waveform branch looks fine, which is why a smoke test will not catch
it. It will show up as silence or noise under a live set. Selective FP16 is a
later size optimisation and must not be attempted without re-running the numeric
verification above. The verification gate in the script is what stops this.

## The transform contract Swift must reproduce

Read `docs/plans/dj-stems-model.md` §5 for the full contract (model sample rate
44 100 Hz, segment 343 980 frames, nfft 4096, hop 1024, periodic Hann,
`normalized=True`, `center=True`, sources order `['drums', 'bass', 'other',
'vocals']` — **not** `StemKind` order). The golden vectors for the Swift tests
are exported from `reference.pt`; the tests compare against those saved torch
tensors and **never** assert STFT/ISTFT round-trip identity, because Demucs's
pair is not invertible (the forward drops the Nyquist bin and trims two frames
each end; measured round-trip error on unit-variance noise is 1.54).
