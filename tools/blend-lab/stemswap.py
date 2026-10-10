#!/usr/bin/env python3
"""Stem hand-over blends (2026-10-09) for pairs whose groove can't be read (techno, deep house).

The groove gate refuses these pairs: their bands disagree, so no reading places the incoming beat
to the ~5 ms that stops flam. Instead of overlapping two drum layers, only the melodic parts
overlap; drums and bass are handed over in one cut on the swap downbeat.

1. Stems: harmonic/percussive separation (Fitzgerald median filtering, Wiener masks), stereo.
2. Swap point as djmix.py (incoming drop x outgoing double drop / bass exit / phrase line).
3. Placement: the groove (groove.py) read on the drum stems only, at 64 and 128 beats, when the two
   agree within 5 ms. Validated on the four approved dj2 placements: the drum-stem reading is within
   4 ms of them, while the full-mix reading can't be trusted on these pairs. Otherwise the grids alone.
   The first grid-only render was 54 ms (techno) / 47 ms (deep house) late; the owner heard deep
   house drift once the outgoing melody played over the incoming drums.
4. 64 beats: the incoming's melodic stem above 150 Hz fades in over 16 beats; on the swap downbeat
   (beat 32) the outgoing's drums and bass stop and the incoming's start; the outgoing's melodic
   stem (above 150 Hz) fades out over the last 16 beats.

Usage: stemswap.py <tracks.json> <out-dir> <cache> <from>:<to>:<label> ...
"""
import json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault("BLEND_STRETCHER", "apple")
from blend import SR, decode, fetch, rms_db, leading_silence, mmss, smooth, write_wav  # noqa: E402
from lock import low_env, audio_period, regular_grid, place  # noqa: E402
from align import stretch  # noqa: E402
import djmix  # noqa: E402
import groove  # noqa: E402
import lock  # noqa: E402
lock.VARIANTS = ("bass-swap",)

OVERLAP, HALF = 64, 32


def stems(audio, nfft=4096, hop=1024, kh=17, kp=31):
    """(harmonic, percussive) stereo, masks from the mid signal applied to each channel."""
    from scipy.ndimage import median_filter
    from scipy.signal import stft, istft
    _, _, Z = stft(audio.mean(axis=1), SR, nperseg=nfft, noverlap=nfft - hop)
    S = np.abs(Z)
    H = median_filter(S, size=(1, kh), mode="nearest")
    P = median_filter(S, size=(kp, 1), mode="nearest")
    mh = H ** 2 / (H ** 2 + P ** 2 + 1e-12)
    harm = np.zeros_like(audio)
    for c in range(2):
        _, _, Zc = stft(audio[:, c], SR, nperseg=nfft, noverlap=nfft - hop)
        _, y = istft(Zc * mh, SR, nperseg=nfft, noverlap=nfft - hop)
        harm[:, c] = y[:len(audio)]
    return harm.astype(np.float32), (audio - harm).astype(np.float32)


def highpass(x, hz=150):
    X = np.fft.rfft(x, axis=0); f = np.fft.rfftfreq(len(x), 1 / SR)
    g = np.where(f < hz, (f / hz) ** 4 / (1 + (f / hz) ** 4), 1.0)   # 4th-order-like roll-off below hz
    X *= g[:, None]
    return np.fft.irfft(X, len(x), axis=0).astype(np.float32)


def render(spec, tracks, cache, out_dir):
    a_id, b_id, label = spec
    TA, TB = tracks[a_id], tracks[b_id]
    a_path, b_path = fetch(TA, cache, a_id), fetch(TB, cache, b_id)
    a = decode(a_path); b_src = decode(b_path)
    pa, pha, _ = audio_period(low_env(a), TA["bpm"])
    pb, phb, _ = audio_period(low_env(b_src), TB["bpm"])
    ratio = pb / pa
    b = decode(stretch(b_path, ratio, cache))
    A = djmix.Track(a, regular_grid(pa, pha, len(a) / SR))
    B = djmix.Track(b, regular_grid(pb / ratio, phb / ratio, len(b) / SR))
    sil = int(np.searchsorted(B.grid, leading_silence(b)))
    sa, style = djmix.outgoing_points(A)[0]
    sb, why = djmix.incoming_points(B, sil)[0]
    start_a = A.grid[sa - HALF]
    shift_t = start_a - (B.grid[sb] - HALF * pa)
    print(f"{label}: outgoing {style} {mmss(A.grid[sa])}, incoming {why} {mmss(B.grid[sb] * ratio)} (own time), "
          f"x{ratio:.5f}; separating stems...", flush=True)
    a_h, a_p = stems(a)
    b_h, b_p = stems(b)
    BA, BB = groove.split(a_p), groove.split(b_p)
    lags = [groove.offset(BA, BB, start_a - nb * pa, start_a + OVERLAP * pa, nb, pa, shift_t) for nb in (64, 128)]
    placed = "grids only"
    if all(g is not None for g in lags) and abs(lags[0][0] - lags[1][0]) <= 0.005:
        lag = (lags[0][0] + lags[1][0]) / 2
        shift_t -= lag
        placed = f"drum-stem groove: incoming was {lag*1000:+.1f} ms late (64b {lags[0][0]*1000:+.1f}, 128b {lags[1][0]*1000:+.1f})"
    print(f"  placement: {placed}", flush=True)
    shift = int(round(shift_t * SR))
    a_hh, b_hh = highpass(a_h), highpass(b_h)
    gain = 10 ** ((rms_db(a) - rms_db(b)) / 20)
    n = len(b) + shift
    inc, inc_hh = place(b, shift, n), place(b_hh, shift, n)
    s0 = int(round(start_a * SR)); n_ov = int(round(OVERLAP * pa * SR)); swap_s = s0 + int(round(HALF * pa * SR))
    beat = np.arange(n_ov) / (pa * SR)
    mix = np.zeros((n, 2), np.float32)
    mix[:swap_s] = a[:swap_s]                                   # outgoing whole up to the swap downbeat
    # A 2 ms ramp at the cut so neither drum layer clicks.
    r = int(0.002 * SR); ramp = np.linspace(1, 0, r)[:, None]
    mix[swap_s - r:swap_s] = a[swap_s - r:swap_s] * ramp + a_hh[swap_s - r:swap_s] * (1 - ramp)
    out_tail = 1 - smooth((beat - 48) / 16)                     # outgoing melodic stem fades over the last 4 bars
    seg = slice(swap_s, s0 + n_ov)
    k = np.arange(swap_s - s0, n_ov)
    m = min(len(k), len(a_hh) - swap_s)
    mix[swap_s:swap_s + m] += a_hh[swap_s:swap_s + m] * out_tail[k[:m], None]
    in_mel = smooth(beat / 16)                                  # incoming melodic stem in over 4 bars
    pre = slice(s0, swap_s)
    mix[pre] += inc_hh[pre] * in_mel[:swap_s - s0, None] * gain
    mix[swap_s - r:swap_s] += (inc[swap_s - r:swap_s] - inc_hh[swap_s - r:swap_s]) * (1 - ramp) * gain
    mix[swap_s:] += inc[swap_s:] * gain                        # incoming whole from the swap downbeat
    name = os.path.abspath(os.path.join(out_dir, f"{label}__stem-handover.wav"))
    write_wav(name, mix)
    marks = [("blend starts: incoming melody (no drums, no bass) fades in", start_a),
             ("drums and bass hand over on the downbeat", swap_s / SR),
             ("outgoing melody fades out", start_a + 48 * pa), ("blend ends", start_a + OVERLAP * pa)]
    print(f"  {name}\n  " + " · ".join(mmss(t) for _, t in marks))
    why_text = f"outgoing {style} at {mmss(A.grid[sa])}, incoming {why} at {mmss(B.grid[sb] * ratio)}; {placed}"
    out = [{"file": name, "label": label, "marks": marks, "why": why_text, "style": "stem hand-over"}]
    # The same placement as an ordinary dj2 bass-swap blend, for comparison.
    if placed != "grids only":
        res = lock.mix_variants(f"{label}__drum-placed", "dj", TA, TB, a, a_path, stretch(b_path, ratio, cache),
                                place(b, shift, n), shift, n, np.zeros(n), start_a, s0, n_ov=n_ov, pa=pa, pb=pb,
                                ratio=ratio, overlap=OVERLAP, gain=gain, out_dir=out_dir)
        for r in res:
            print(f"  {r['file']}")
            out.append({"file": r["file"], "label": label, "marks": r["marks"], "why": why_text, "style": "dj2 bass swap"})
    return out


def main():
    cand, out_dir, cache = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    tracks = json.load(open(cand))
    res = [r for s in sys.argv[4:] for r in render(tuple(s.split(":")), tracks, cache, out_dir)]
    lines = ["# Listening guide: stem hand-over (techno, deep house)", ""]
    for r in res:
        lines += [f"## {r['label']}: {r['style']}", f"`{r['file']}`", "", f"- {r['why']}"]
        lines += [f"- **{mmss(t)}**: {m}" for m, t in r["marks"]] + [""]
    open(os.path.join(out_dir, "LISTENING-GUIDE.md"), "w").write("\n".join(lines))


if __name__ == "__main__":
    main()
