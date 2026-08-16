#!/usr/bin/env python3
"""Export the Swift golden-test fixture from reference.pt (plan dj-stems-model.md S2).

reference.pt's tensors are ~76 MB; a multi-megabyte fixture in the repo is not
acceptable, and the S2 golden tests must not depend on the model being present.
So this script derives a compact, fully torch-computed sub-golden:

  forward  — the real spectrogram (mag) of the first 40960 samples of each
             channel of `audio` (40 frames @ 1024 hop). The reference is the
             torch `_spec`+`_magnitude` of that exact slice; Swift's
             `DemucsSpectrogram.forward` must reproduce it to max|d| <= 1e-4.
             (Frames 0..37 of this are bit-identical to the first 38 frames of
             reference.pt's `mag`; the last two touch the right-hand reflect
             padding and are edge-only, which is why the golden is computed
             from the slice rather than sliced from `mag`.)
  inverse  — the model `_ispec` of the first 16 frames of `spec[0, 0]` (source
             drums, cac layout [4, 2048, 16]), full 343 980-frame output per
             channel. Swift's `DemucsSpectrogram.inverse` must reproduce it to
             max|d| <= 1e-4.

Outputs are compared on a deterministic subsampled slice: every 97th element
with its flat index, so the fixture stays compact and the rule is stated in the
Swift test for reproduction from reference.pt.

Writes Tests/DJTests/Fixtures/demucs_stem_golden.bin (little-endian):

  header:
    magic "DSMG"          4 bytes
    u32 version           1
    u32 stride            97
    u32 forwardFrames     40960
    u32 forwardMagFrames  40
    u32 forwardMagCount   N1
    u32 inverseSpecFrames 16
    u32 inverseCount      N2
  body:
    f32[forwardFrames]  forward audio left
    f32[forwardFrames]  forward audio right
    u32 + f32 × N1      forward mag ref (flat index into [4,2048,40] plane-major)
    f32[4*2048*16]      inverse spec input (source 0, cac layout)
    u32 + f32 × N2      inverse ispec ref (flat index into [2,343980] L then R)

Run from the repo root:  .venv-demucs/bin/python tools/demucs-coreml/export_fixtures.py
"""
import math
import pathlib
import struct

import torch
import torch.nn.functional as F

from demucs.hdemucs import pad1d
from demucs.spec import spectro, ispectro

HERE = pathlib.Path(__file__).parent
FIXTURE = pathlib.Path(__file__).parent.parent.parent / "Tests/DJTests/Fixtures/demucs_stem_golden.bin"

STRIDE = 97
NFFT, HOP = 4096, 1024


def manual_ispec(z, length):
    """torch.istft(normalized=True, center=True) — bit-identical to ATen.

    torch.istft's NOLA check rejects a short spec, so the sub-golden cannot use
    it directly; this replicates the exact algorithm from SpectralOps.cpp
    (verified bit-for-bit, max|d| 0.0, against torch.istft on the full 340-frame
    spec): _fft_c2r with by_root_n (plain irfft scaled by sqrt(n_fft)), window,
    overlap-add, divide by the overlap-add of the squared window, slice from
    n_fft/2 for `length` frames.
    """
    *other, freqs, n_frames = z.shape
    z = z.reshape(-1, freqs, n_frames)
    expected = NFFT + HOP * (n_frames - 1)
    irfft = torch.fft.irfft(z, n=NFFT, dim=-2) * math.sqrt(NFFT)
    windowed = irfft * torch.hann_window(NFFT)[:, None]
    y = torch.zeros(z.shape[0], expected)
    envelope = torch.zeros(expected)
    for t in range(n_frames):
        y[:, t * HOP:t * HOP + NFFT] += windowed[:, :, t]
        envelope[t * HOP:t * HOP + NFFT] += torch.hann_window(NFFT) ** 2
    start = NFFT // 2
    out = y[:, start:min(expected, start + length)] / envelope[start:min(expected, start + length)]
    if start + length > expected:
        out = F.pad(out, (0, start + length - expected))
    return out.reshape(*other, length)


def subsample(tensor, stride):
    flat = tensor.reshape(-1)
    indices = list(range(0, flat.numel(), stride))
    return indices, flat[indices]


def main():
    ref = torch.load(HERE / "reference.pt", map_location="cpu", weights_only=False)

    # --- forward sub-golden: _spec + _magnitude of the first 40960 samples ---
    audio = ref["audio"]                       # [1, 2, 343980]
    short = audio[:, :, :40960].contiguous()
    le = math.ceil(40960 / HOP)
    pad = HOP // 2 * 3
    x = pad1d(short, (pad, pad + le * HOP - 40960), mode="reflect")
    z = spectro(x, NFFT, HOP)[..., :-1, :][..., 2:2 + le]
    mag = torch.view_as_real(z).permute(0, 1, 4, 2, 3).reshape(1, 4, 2048, le)
    assert mag.shape == (1, 4, 2048, 40), mag.shape
    fwd_idx, fwd_ref = subsample(mag[0], STRIDE)

    # --- inverse sub-golden: _ispec of spec[0, 0, :, :, :16] ---
    spec = ref["spec"]                         # [1, 4, 4, 2048, 336] (real, cac layout)
    # _mask unpacks the cac layout back to complex before _ispec sees it.
    s16 = spec[0:1, 0:1, :, :, :16]
    b, s, c, fr, t = s16.shape
    s16 = torch.view_as_complex(
        s16.view(b, s, -1, 2, fr, t).permute(0, 1, 2, 4, 5, 3).contiguous())
    s16 = F.pad(s16, (0, 0, 0, 1))             # restore the Nyquist bin (zero)
    s16 = F.pad(s16, (2, 2))                   # two zero frames each end
    length = int(343980)
    le_full = HOP * math.ceil(length / HOP) + 2 * (HOP // 2 * 3)
    out = manual_ispec(s16, le_full)           # [1, 1, 4, 347136]
    out = out[..., 1536:1536 + length]         # [1, 1, 4, 343980]
    inv_idx, inv_ref = subsample(out[0, 0], STRIDE)  # [2, 343980]

    # --- write the fixture ---
    left = short[0, 0].numpy().astype("<f4").tobytes()
    right = short[0, 1].numpy().astype("<f4").tobytes()
    header = struct.pack(
        "<4sIIIIIII",
        b"DSMG", 1, STRIDE,
        40960, le, len(fwd_idx),
        16, len(inv_idx),
    )
    fwd_body = b"".join(
        struct.pack("<If", i, float(v)) for i, v in zip(fwd_idx, fwd_ref.tolist()))
    spec_body = spec[0, 0, :, :, :16].numpy().astype("<f4").tobytes()
    inv_body = b"".join(
        struct.pack("<If", i, float(v)) for i, v in zip(inv_idx, inv_ref.tolist()))

    payload = header + left + right + fwd_body + spec_body + inv_body
    FIXTURE.write_bytes(payload)
    print(f"wrote {FIXTURE} ({len(payload)/1024:.0f} KB)")
    print(f"  forward mag: {mag.shape} -> {len(fwd_idx)} subsampled refs "
          f"(max|d| 0 by construction)")
    print(f"  inverse ispec: {out.shape} -> {len(inv_idx)} subsampled refs")


if __name__ == "__main__":
    main()
