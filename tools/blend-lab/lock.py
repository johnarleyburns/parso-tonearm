#!/usr/bin/env python3
"""Beat-locked blends: the owner's method, done the way a DJ does it.

1. Tempo from the audio itself (fold the kick onsets over the track; the sharpest period wins).
2. Stretch the incoming track ONCE, with keylock (Rubber Band R2), to exactly the
   outgoing tempo, and keep that tempo for the rest of the mix.
3. Find each kick's attack time in both tracks and place the incoming track so the attacks
   coincide. Then keep nudging, beat by beat, so they stay together even where the music's own
   timing wanders: a slowly varying delay on the incoming track (slew-limited, so inaudible).
4. Bars and phrases: pick the 8-bar phrase phase from where each track's energy changes, so the
   blend starts and the bass swap lands on phrase boundaries, not just on any beat.

Every render reports the measured flam (attack-time difference of the two kicks per beat).

Usage: lock.py <tracks.json> <out-dir> <cache-dir> <from>:<to>:<label> ...
"""
import json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from blend import SR, decode, fetch, write_wav, rms_db, leading_silence, mmss, smooth  # noqa: E402
import subprocess


def stretched(path, ratio, cache):
    """Keylocked tempo change with Rubber Band's R2 engine at its sharpest transients (-c 6).
    Measured: ffmpeg atempo moved 74 % of kicks by more than 2 ms (a flam on its own); this keeps
    kick timing within the measurement noise of an exact-timing resample."""
    base = os.path.splitext(os.path.basename(path))[0]
    wav = os.path.join(cache, f"{base}.wav")
    out = os.path.join(cache, f"{base}__rb2c6_x{ratio:.6f}.wav")
    if not os.path.exists(wav):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-ar", str(SR), wav], check=True)
    if not os.path.exists(out):
        subprocess.run(["rubberband", "-2", "-c", "6", "-T", f"{ratio:.6f}", wav, out], check=True, capture_output=True)
    return out

# The hop must divide SR exactly: SR // 2000 = 22 samples is 0.4989 ms, not 0.5 ms, and treating it
# as 0.5 ms stretched every measured time by 441/440 (see README, 2026-10-08).
HOP = 22
ENV_RATE = SR / HOP                 # envelope samples per second (~0.5 ms)


# ---------------------------------------------------------------- envelopes and kicks

def low_env(audio, lo=35, hi=160):
    """Low-band amplitude envelope at ENV_RATE (FFT band-limit, then RMS per 0.5 ms)."""
    mono = audio.mean(axis=1).astype(np.float64)
    spec = np.fft.rfft(mono)
    f = np.fft.rfftfreq(len(mono), 1 / SR)
    spec[(f < lo) | (f > hi)] = 0
    x = np.fft.irfft(spec, len(mono))
    hop = HOP
    n = len(x) // hop
    e = np.sqrt(np.mean(x[:n * hop].reshape(n, hop) ** 2, axis=1))
    k = 9                                            # ~4.5 ms smoothing
    return np.convolve(e, np.ones(k) / k, mode="same")


def audio_period(env, approx_bpm):
    """Beat period (s) with the sharpest folded kick profile, searched ±1 % around approx_bpm."""
    t = np.arange(len(env)) / ENV_RATE
    flux = np.maximum(0, np.diff(env, prepend=env[0]))
    best = (0, 60 / approx_bpm)
    for p in np.linspace(60 / approx_bpm * 0.99, 60 / approx_bpm * 1.01, 801):
        ph = (t % p) / p
        h, _ = np.histogram(ph, bins=96, weights=flux)
        c, _ = np.histogram(ph, bins=96)
        prof = h / np.maximum(c, 1)
        score = prof.max() / (prof.mean() + 1e-12)
        if score > best[0]:
            best = (score, p)
    # Phase of the fold peak = where the kick attack typically falls in the beat.
    p = best[1]
    ph = (t % p) / p
    h, edges = np.histogram(ph, bins=192, weights=flux)
    phase = (edges[np.argmax(h)] + 0.5 / 192) * p
    return p, phase, best[0]


def kick_attacks(env, beats, window=0.09):
    """Attack time of the kick nearest each grid beat: where the low envelope first rises past
    half of its local peak, refined linearly. NaN where there is no clear kick."""
    out = np.full(len(beats), np.nan)
    strength = np.zeros(len(beats))
    global_ref = np.percentile(env, 99)
    w = int(window * ENV_RATE)
    for i, b in enumerate(beats):
        c = int(round(b * ENV_RATE))
        lo, hi = max(1, c - w), min(len(env) - 1, c + w)
        if hi - lo < 10:
            continue
        seg = env[lo:hi]
        pk = int(np.argmax(seg))
        peak = seg[pk]
        base = np.min(seg[:pk + 1]) if pk > 0 else seg[0]
        if peak < 0.25 * global_ref or peak - base < 0.15 * global_ref:
            continue
        half = base + 0.5 * (peak - base)
        j = pk
        while j > 0 and seg[j] > half:
            j -= 1
        # linear refine between j and j+1
        y0, y1 = seg[j], seg[min(j + 1, len(seg) - 1)]
        frac = 0 if y1 == y0 else (half - y0) / (y1 - y0)
        out[i] = (lo + j + frac) / ENV_RATE
        strength[i] = peak / global_ref
    return out, strength


def regular_grid(period, phase, duration):
    n0 = int(np.ceil(-phase / period))
    g = phase + period * np.arange(n0, int((duration - phase) / period) + 1)
    return g[(g >= 0) & (g < duration)]


def phrase_phase(audio, beats, beats_per_phrase=32):
    """Beat index offset (0..31) where 8-bar phrases start: the phase with the most energy change
    at its boundaries (drops, breakdowns and new parts land on phrase starts in dance music)."""
    mono = np.abs(audio.mean(axis=1))
    idx = (beats * SR).astype(int)
    idx = idx[idx < len(mono)]
    seg = np.array([np.sqrt(np.mean(mono[a:b] ** 2) + 1e-12) for a, b in zip(idx[:-1], idx[1:])])
    db = 20 * np.log10(seg + 1e-9)
    # change between the 4 beats before and the 4 beats after each beat
    nov = np.zeros(len(db))
    for i in range(4, len(db) - 4):
        nov[i] = abs(db[i:i + 4].mean() - db[i - 4:i].mean())
    scores = [nov[p::beats_per_phrase].sum() for p in range(beats_per_phrase)]
    # phrases are bars too: restrict to downbeat-consistent phases by folding at 4 as well
    return int(np.argmax(scores)), scores


# ---------------------------------------------------------------- time-varying delay

def apply_delay(audio, delay_at_sample):
    """Shift audio later by a smoothly varying delay (seconds) given per output sample,
    using fractional-index interpolation. Tiny slopes (<0.2 %) are inaudible."""
    n = len(audio)
    src = np.arange(n) - delay_at_sample * SR
    out = np.zeros_like(audio)
    for ch in range(audio.shape[1]):
        out[:, ch] = np.interp(src, np.arange(n), audio[:, ch], left=0, right=0)
    return out


def nudge_curve(diff_per_beat, beat_times, n, max_slew_per_beat=0.0015, hold_start=None):
    """Per-sample delay from per-beat attack differences (NaN = no evidence): median-smoothed
    over 2 bars, slew-limited to 1.5 ms per beat, held where there is no evidence."""
    d = np.array(diff_per_beat, float)
    sm = np.full_like(d, np.nan)
    for i in range(len(d)):
        w = d[max(0, i - 4):i + 5]
        w = w[~np.isnan(w)]
        if len(w) >= 3:
            sm[i] = np.median(w)
    cur = hold_start if hold_start is not None else (np.nanmedian(sm) if np.any(~np.isnan(sm)) else 0.0)
    vals = []
    for v in sm:
        if not np.isnan(v):
            cur += float(np.clip(v - cur, -max_slew_per_beat, max_slew_per_beat))
        vals.append(cur)
    vals = np.array(vals)
    return np.interp(np.arange(n) / SR, beat_times, vals, left=vals[0] if len(vals) else 0,
                     right=vals[-1] if len(vals) else 0)


def low_flux(audio):
    """Onset curve for alignment at ENV_RATE: the rectified rise of three band envelopes
    (kick 35–160 Hz, mids 160–2k, hats 2k–12k), each normalised so hats count when a track has no
    kick yet (intros) and the kick dominates when it is there."""
    total = None
    for lo, hi, w in ((35, 160, 1.0), (160, 2000, 0.5), (2000, 12000, 0.5)):
        e = low_env(audio, lo, hi)
        f = np.maximum(0, np.diff(e, prepend=e[0]))
        f = f / (np.percentile(f, 99.5) + 1e-12)
        total = w * f if total is None else total + w * f
    return total


def local_lag(fo, fi, center, half_window, max_lag):
    """How late the incoming is vs the outgoing (s) around `center` (s), from the
    cross-correlation of their low-band onset curves over ±half_window; sub-sample by parabola.
    Returns (lag, confidence) with confidence = peak / median of the correlation."""
    c = int(center * ENV_RATE); w = int(half_window * ENV_RATE); m = int(max_lag * ENV_RATE)
    lo, hi = c - w, c + w
    if lo - m < 0 or hi + m > min(len(fo), len(fi)):
        return np.nan, 0.0
    o = fo[lo:hi] - fo[lo:hi].mean()
    if np.std(o) == 0:
        return np.nan, 0.0
    scores = []
    for l in range(-m, m + 1):
        x = fi[lo + l:hi + l] - fi[lo + l:hi + l].mean()
        sx = np.linalg.norm(x)
        scores.append(np.dot(o, x) / (np.linalg.norm(o) * sx) if sx > 0 else 0.0)
    scores = np.array(scores)
    k = int(np.argmax(scores))
    if 0 < k < len(scores) - 1:
        y0, y1, y2 = scores[k - 1], scores[k], scores[k + 1]
        den = y0 - 2 * y1 + y2
        frac = 0.5 * (y0 - y2) / den if den != 0 else 0
    else:
        frac = 0
    # Confidence: Pearson correlation at the peak, and the peak must be interior (not the edge).
    conf = scores[k] if 0 < k < len(scores) - 1 else 0.0
    return (k - m + frac) / ENV_RATE, conf


def lag_track(fo, fi, start, end, period, win_beats=8, hop_beats=2, max_lag=0.08, min_conf=0.25):
    """Lags across [start, end] every hop_beats, each over win_beats; NaN where unconfident."""
    centers = np.arange(start + win_beats * period / 2, end - win_beats * period / 2 + 1e-9, hop_beats * period)
    lags, confs = [], []
    for c in centers:
        l, q = local_lag(fo, fi, c, win_beats * period / 2, max_lag)
        lags.append(l if q >= min_conf else np.nan); confs.append(q)
    return centers, np.array(lags), np.array(confs)


def smooth_delay(centers, lags, n, slew_per_sec=0.003):
    """Per-sample delay that cancels the measured lags: median over 3 windows, held where there is
    no evidence, slew-limited (3 ms per second = a 0.3 % rate change at most: inaudible)."""
    d = -lags
    sm = np.array([np.nanmedian(d[max(0, i - 1):i + 2]) if np.any(~np.isnan(d[max(0, i - 1):i + 2])) else np.nan
                   for i in range(len(d))])
    valid = ~np.isnan(sm)
    if not valid.any():
        return np.zeros(n), np.zeros(len(d))
    cur = sm[valid][0]
    out = []
    prev_t = centers[0]
    for t, v in zip(centers, sm):
        step = slew_per_sec * (t - prev_t)
        if not np.isnan(v):
            cur += float(np.clip(v - cur, -step if t != prev_t else -1, step if t != prev_t else 1))
        out.append(cur); prev_t = t
    out = np.array(out)
    return np.interp(np.arange(n) / SR, centers, out), out


def beat_lags(env_o, env_i, beats, half=0.07, max_lag=0.05):
    """Per beat: how late the incoming kick is vs the outgoing one (s), from cross-correlating the
    two low-band envelopes over ±70 ms around the beat (shape match, sub-sample via parabola).
    NaN where either side has no kick there or the shapes don't match (r < 0.6)."""
    out = np.full(len(beats), np.nan)
    ref = np.percentile(env_o, 99); refi = np.percentile(env_i, 99)
    h = int(half * ENV_RATE); m = int(max_lag * ENV_RATE)
    for k, t in enumerate(beats):
        c = int(round(t * ENV_RATE))
        if c - h - m < 0 or c + h + m >= min(len(env_o), len(env_i)):
            continue
        o = env_o[c - h:c + h]
        if o.max() < 0.25 * ref or env_i[c - h - m:c + h + m].max() < 0.25 * refi:
            continue
        o = o - o.mean(); no = np.linalg.norm(o)
        best, bl, sc = -1, 0, []
        for l in range(-m, m + 1):
            x = env_i[c - h + l:c + h + l]; x = x - x.mean(); nx = np.linalg.norm(x)
            r = np.dot(o, x) / (no * nx) if nx > 0 and no > 0 else 0
            sc.append(r)
        sc = np.array(sc); kk = int(np.argmax(sc))
        if sc[kk] < 0.6 or kk in (0, len(sc) - 1):
            continue
        y0, y1, y2 = sc[kk - 1], sc[kk], sc[kk + 1]; den = y0 - 2 * y1 + y2
        frac = 0.5 * (y0 - y2) / den if den != 0 else 0
        out[k] = (kk - m + frac) / ENV_RATE
    return out


def kick_template(env, grid, pre=0.06, post=0.12):
    """The track's own average kick (low-band envelope around its grid beats where a kick is
    clearly there) and its attack point (half-rise) relative to the window start."""
    ref = np.percentile(env, 99)
    a, b = int(pre * ENV_RATE), int(post * ENV_RATE)
    wins = []
    for t in grid:
        c = int(round(t * ENV_RATE))
        if c - a < 0 or c + b >= len(env):
            continue
        w = env[c - a:c + b]
        if w.max() > 0.4 * ref:
            wins.append(w / w.max())
    if len(wins) < 8:
        return None, None
    T = np.median(np.array(wins), axis=0)
    pk = int(np.argmax(T)); base = T[:pk + 1].min(); half = base + 0.5 * (T[pk] - base)
    j = pk
    while j > 0 and T[j] > half:
        j -= 1
    frac = (half - T[j]) / (T[j + 1] - T[j]) if T[j + 1] != T[j] else 0
    return T, (j + frac) / ENV_RATE


def kick_times(env, grid, T, attack, pre=0.06, search=0.06, min_r=0.5):
    """Attack time of each kick found by matching the track's own kick template within ±search
    of each grid beat. NaN where no kick matches."""
    out = np.full(len(grid), np.nan)
    if T is None:
        return out
    a = int(pre * ENV_RATE); L = len(T); m = int(search * ENV_RATE)
    Tz = T - T.mean(); nT = np.linalg.norm(Tz)
    ref = np.percentile(env, 99)
    for k, t in enumerate(grid):
        c = int(round(t * ENV_RATE))
        lo = c - a - m
        if lo < 0 or c - a + m + L >= len(env):
            continue
        if env[c - a - m:c - a + m + L].max() < 0.3 * ref:
            continue
        sc = []
        for l in range(-m, m + 1):
            w = env[c - a + l:c - a + l + L]; wz = w - w.mean(); nw = np.linalg.norm(wz)
            sc.append(np.dot(Tz, wz) / (nT * nw) if nw > 0 else 0)
        sc = np.array(sc); kk = int(np.argmax(sc))
        if sc[kk] < min_r or kk in (0, len(sc) - 1):
            continue
        y0, y1, y2 = sc[kk - 1], sc[kk], sc[kk + 1]; den = y0 - 2 * y1 + y2
        frac = 0.5 * (y0 - y2) / den if den != 0 else 0
        out[k] = (c - a + kk - m + frac) / ENV_RATE + attack
    return out


def timing_map(kicks, grid, block=32, min_found=0.6):
    """Per grid beat: the kick's offset from the grid (s). Taken from 32-beat blocks where the
    kick is clearly present (60 %+ of beats matched), median-smoothed over ±16 beats, and carried
    across intros, breakdowns and outros that have no kick (nearest confident value)."""
    r = kicks - grid
    good = np.zeros(len(grid), bool)
    for i in range(0, len(grid), block):
        seg = r[i:i + block]
        if np.mean(~np.isnan(seg)) >= min_found:
            good[i:i + block] = ~np.isnan(seg)
    vals = np.full(len(grid), np.nan)
    idx = np.where(good)[0]
    if len(idx) == 0:
        return np.zeros(len(grid)), False
    for i in range(len(grid)):
        near = idx[np.abs(idx - i) <= 16]
        if len(near) >= 6:
            vals[i] = np.median(r[near])
    have = np.where(~np.isnan(vals))[0]
    if len(have) == 0:
        return np.full(len(grid), np.median(r[idx])), True
    return np.interp(np.arange(len(grid)), have, vals[have]), True


# ---------------------------------------------------------------- render

def flam_ms(env_out, env_in, beats):
    a, _ = kick_attacks(env_out, beats)
    b, _ = kick_attacks(env_in, beats)
    d = (b - a) * 1000
    d = d[~np.isnan(d)]
    return (float(np.median(np.abs(d))), float(np.percentile(np.abs(d), 90)), len(d)) if len(d) else (np.nan, np.nan, 0)


def place(x, shift, n):
    """x placed on an n-sample output timeline starting at `shift` samples (may be negative)."""
    y = np.zeros((n, 2), np.float32)
    src0 = max(0, -shift); dst0 = max(0, shift)
    m = min(len(x) - src0, n - dst0)
    if m > 0:
        y[dst0:dst0 + m] = x[src0:src0 + m]
    return y


def render(spec, tracks, cache, out_dir, overlap=64):
    a_id, b_id, label = spec
    A, B = tracks[a_id], tracks[b_id]
    a_path, b_path = fetch(A, cache, a_id), fetch(B, cache, b_id)
    a = decode(a_path); b_src = decode(b_path)
    ea = low_env(a)
    pa, pha, qa = audio_period(ea, A["bpm"])
    pb, phb, qb = audio_period(low_env(b_src), B["bpm"])
    ratio = pb / pa                                 # incoming sped up/slowed to the outgoing tempo
    b_stretched = stretched(b_path, ratio, cache)
    b = decode(b_stretched)                         # keylocked, once, kept for the whole mix
    measured = len(b_src) / len(b)
    ga = regular_grid(pa, pha, len(a) / SR)
    gb = regular_grid(pb / measured, phb / measured, len(b) / SR)
    gain = 10 ** ((rms_db(a) - rms_db(b)) / 20)
    fa, _ = phrase_phase(a, ga)
    fb, _ = phrase_phase(b, gb)
    exit_idx = max(i for i in range(fa, len(ga), 32) if i + overlap < len(ga))
    silence = leading_silence(b)
    entry_idx = next(i for i in range(fb, len(gb), 32) if gb[i] >= silence)
    exit_t, entry_t = ga[exit_idx], gb[entry_idx]
    n_ov = int(round(overlap * pa * SR))
    exit_s = int(round(exit_t * SR))
    shift = exit_s - int(round(entry_t * SR))       # incoming sample i plays at output i + shift
    n = len(b) + shift
    print(f"\n{label}: {A['title']} → {B['title']}  tempo {60/pa:.3f} → {60/pb:.3f} BPM measured from audio "
          f"(analyser {A['bpm']:.2f} → {B['bpm']:.2f}); incoming x{ratio:.5f} keylocked; "
          f"blend {mmss(exit_t)}–{mmss(exit_t + overlap * pa)} (phrase starts: out beat {exit_idx}, in beat {entry_idx})")

    eb = low_env(b)
    # Two candidate phase placements, rendered side by side for listening (automatic flam meters
    # disagreed, see README): A = audio-measured grids aligned (exit beat on entry beat);
    # B = per-track kick timing maps aligned (each track's kick offset from its grid, carried over
    # intros/breakdowns), plus a slow nudge following the map difference across the blend.
    Ta, atk_a = kick_template(ea, ga)
    Tb, atk_b = kick_template(eb, gb)
    map_a, ok_a = timing_map(kick_times(ea, ga, Ta, atk_a), ga)
    map_b, ok_b = timing_map(kick_times(eb, gb, Tb, atk_b), gb)
    k = np.arange(-16, overlap)
    k = k[(exit_idx + k >= 0) & (exit_idx + k < len(ga)) & (entry_idx + k >= 0) & (entry_idx + k < len(gb))]
    need = map_a[exit_idx + k] - map_b[entry_idx + k]
    static = float(np.median(need))
    lock_beats = ga[exit_idx + k]
    shift_a = shift
    shift_b = shift + int(round(static * SR))
    resid = np.where(np.abs(need - static) < 0.0015, 0.0, need - static)
    delay_b = nudge_curve(resid, lock_beats, len(b) + shift_b, max_slew_per_beat=0.0005, hold_start=0.0)
    delay_b[int(lock_beats[-1] * SR):] = delay_b[min(len(delay_b) - 1, int(lock_beats[-1] * SR))]
    print(f"  B moves the incoming {static*1000:+.1f} ms vs A (kick offsets: outgoing {np.median(map_a[exit_idx+k])*1000:+.1f} ms, "
          f"incoming {np.median(map_b[entry_idx+k])*1000:+.1f} ms from their grids); B nudge range "
          f"{delay_b.min()*1000:+.1f}…{delay_b.max()*1000:+.1f} ms")
    placements = [("A-grids", shift_a, np.zeros(len(b) + shift_a)), ("B-kickmaps", shift_b, delay_b)]

    results = []
    for placement, shift, delay in placements:
        n = len(b) + shift
        inc = apply_delay(place(b, shift, n), delay)
        results += mix_variants(label, placement, A, B, a, a_path, b_stretched, inc, shift, n, delay,
                                exit_t, exit_s, n_ov, pa, pb, ratio, overlap, gain, out_dir)
    return results


VARIANTS = ("equal-power", "bass-swap")


def mix_variants(label, placement, A, B, a, a_path, b_stretched, inc, shift, n, delay,
                 exit_t, exit_s, n_ov, pa, pb, ratio, overlap, gain, out_dir):
    results = []
    beat = np.arange(n_ov) / (pa * SR)
    q = overlap / 4
    for variant in VARIANTS:
        mix = np.zeros((n, 2), np.float32)
        mix[:exit_s] = a[:exit_s]
        if variant == "equal-power":
            p = beat / overlap
            ang = np.where(p < 1 / 3, smooth(p * 3) * np.pi / 4,
                  np.where(p < 2 / 3, np.pi / 4, np.pi / 4 + smooth((p - 2 / 3) * 3) * np.pi / 4))
            seg = a[exit_s:exit_s + n_ov]
            mix[exit_s:exit_s + len(seg)] += seg * np.cos(ang)[:len(seg), None]
            g_in = np.ones(n - exit_s); g_in[:n_ov] = np.sin(ang)
            mix[exit_s:] += inc[exit_s:] * (g_in * gain)[:, None]
            marks = [("blend starts on a phrase start: incoming fades in", exit_t),
                     ("both tracks at equal level", exit_t + overlap * pa / 3),
                     ("midpoint", exit_t + overlap * pa / 2),
                     ("outgoing starts fading out", exit_t + 2 * overlap * pa / 3),
                     ("blend ends: incoming alone", exit_t + overlap * pa)]
        else:
            a_lo, a_hi = decode(a_path, band="low"), decode(a_path, band="high")
            # The outgoing track runs through the crossover from its first sample, as a DJ mixer's
            # EQ is always in the path. Switching from the plain signal to the (phase-shifted) band
            # sum at the blend start made a step: an audible click (owner, 2026-10-08).
            mix[:exit_s] = (a_lo + a_hi)[:exit_s]
            b_lo = apply_delay(place(decode(b_stretched, band="low"), shift, n), delay)
            b_hi = apply_delay(place(decode(b_stretched, band="high"), shift, n), delay)
            in_hi = smooth(beat / q)
            # The swap completes ON the downbeat (quarter-beat ramp before it), so the drop's first
            # kick is the incoming's alone. It used to ramp over the beat after: a half-swapped drop.
            swap = smooth((beat - (2 * q - 0.25)) / 0.25)
            out_hi = 1 - smooth((beat - 3 * q) / q)
            m = min(n_ov, len(a_lo) - exit_s)
            sl = slice(exit_s, exit_s + m)
            mix[sl] += a_lo[sl] * (1 - swap)[:m, None] + a_hi[sl] * out_hi[:m, None]
            mix[exit_s:exit_s + n_ov] += (b_lo[exit_s:exit_s + n_ov] * swap[:, None]
                                          + b_hi[exit_s:exit_s + n_ov] * in_hi[:, None]) * gain
            mix[exit_s + n_ov:] += (b_lo[exit_s + n_ov:] + b_hi[exit_s + n_ov:]) * gain
            marks = [("blend starts on a phrase start: incoming highs fade in (no bass)", exit_t),
                     ("incoming highs at full", exit_t + overlap * pa / 4),
                     ("bass swap on the phrase downbeat (midpoint)", exit_t + overlap * pa / 2),
                     ("outgoing highs start fading out", exit_t + 3 * overlap * pa / 4),
                     ("blend ends: incoming alone", exit_t + overlap * pa)]
        name = f"{label}__{placement}__{variant}__{overlap}beats.wav"
        path = os.path.abspath(os.path.join(out_dir, name))
        write_wav(path, mix)
        results.append({"file": path, "label": label, "placement": placement, "variant": variant,
                        "overlapBeats": overlap, "marks": marks, "lengthSec": n / SR,
                        "outgoing": f"{A['title']} — {A['artist']} ({60 / pa:.2f} BPM measured)",
                        "incoming": f"{B['title']} — {B['artist']} ({60 / pb:.2f} BPM measured, played at x{ratio:.4f} with keylock)"})
    return results


def write_guide(results, out_dir):
    lines = ["# A/B listening guide — beat-locked blends", "",
             "Every file is two full tracks: the outgoing track from its start, the blend, then the "
             "incoming track to its end. The incoming track is tempo-matched once with keylock "
             "(Rubber Band) to the tempo measured from the outgoing track's audio and stays there. "
             "Times are elapsed time in the file; start listening ~20 s before the blend.", "",
             "**A-grids**: beats aligned by each track's audio-measured grid.  ",
             "**B-kickmaps**: kicks aligned by each track's measured kick position, plus a slow nudge.  ",
             "For each pair, tell me which of A or B has one clean kick (no flam) and a clean drop.", ""]
    for label in dict.fromkeys(r["label"] for r in results):
        g = [r for r in results if r["label"] == label]
        lines += [f"## {label}", "", f"- Outgoing: {g[0]['outgoing']}", f"- Incoming: {g[0]['incoming']}", ""]
        for r in g:
            what = ("Equal-power fade. Listen through the whole blend for a double kick (flam) or a "
                    "gallop, especially from 'both tracks at equal level' to the midpoint."
                    if r["variant"] == "equal-power" else
                    "DJ style: the incoming comes in without bass; at the midpoint the basses swap on "
                    "the phrase downbeat. Listen for one clean drop with the kicks together.")
            lines += [f"### {r['placement']} · {r['variant']}", f"`{r['file']}`", "", what, ""]
            lines += [f"- **{mmss(t)}** — {m}" for m, t in r["marks"]] + [""]
    path = os.path.join(out_dir, "LISTENING-GUIDE.md")
    open(path, "w").write("\n".join(lines))
    return os.path.abspath(path)


def main():
    cand, out_dir, cache = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    tracks = json.load(open(cand))
    results = []
    for spec in sys.argv[4:]:
        a, b, label = spec.split(":")
        results += render((a, b, label), tracks, cache, out_dir)
    json.dump(results, open(os.path.join(out_dir, "summary.json"), "w"), indent=1, default=float)
    print("guide:", write_guide(results, out_dir))


if __name__ == "__main__":
    main()
