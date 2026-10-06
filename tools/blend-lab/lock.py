#!/usr/bin/env python3
"""Beat-locked blends: the owner's method, done the way a DJ does it.

1. Tempo from the audio itself (fold the kick onsets over the track; the sharpest period wins).
2. Stretch the incoming track ONCE, with keylock (ffmpeg atempo keeps pitch), to exactly the
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

ENV_RATE = 2000                     # envelope samples per second (0.5 ms)


# ---------------------------------------------------------------- envelopes and kicks

def low_env(audio, lo=35, hi=160):
    """Low-band amplitude envelope at ENV_RATE (FFT band-limit, then RMS per 0.5 ms)."""
    mono = audio.mean(axis=1).astype(np.float64)
    spec = np.fft.rfft(mono)
    f = np.fft.rfftfreq(len(mono), 1 / SR)
    spec[(f < lo) | (f > hi)] = 0
    x = np.fft.irfft(spec, len(mono))
    hop = SR // ENV_RATE
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


# ---------------------------------------------------------------- render

def flam_ms(env_out, env_in, beats):
    a, _ = kick_attacks(env_out, beats)
    b, _ = kick_attacks(env_in, beats)
    d = (b - a) * 1000
    d = d[~np.isnan(d)]
    return (float(np.median(np.abs(d))), float(np.percentile(np.abs(d), 90)), len(d)) if len(d) else (np.nan, np.nan, 0)


def render(spec, tracks, cache, out_dir):
    a_id, b_id, label = spec
    A, B = tracks[a_id], tracks[b_id]
    a_path, b_path = fetch(A, cache, a_id), fetch(B, cache, b_id)
    a = decode(a_path); b_src = decode(b_path)
    ea, eb_src = low_env(a), low_env(b_src)
    pa, pha, qa = audio_period(ea, A["bpm"] * 440 / 441)
    pb, phb, qb = audio_period(eb_src, B["bpm"] * 440 / 441)
    ratio = pb / pa                               # >1: incoming sped up to the outgoing tempo
    b = decode(b_path, tempo=ratio)
    measured = len(b_src) / len(b)
    eb = low_env(b)
    pb_s, phb_s = pb / measured, phb / measured   # incoming grid after the stretch
    ga = regular_grid(pa, pha, len(a) / SR)
    gb = regular_grid(pb_s, phb_s, len(b) / SR)
    gain = 10 ** ((rms_db(a) - rms_db(b)) / 20)
    print(f"\n{label}: {A['title']} → {B['title']}  audio tempo {60/pa:.3f} → {60/pb:.3f} BPM "
          f"(analyser {A['bpm']:.2f} → {B['bpm']:.2f}); incoming x{ratio:.5f} keylocked; "
          f"fold sharpness {qa:.1f}/{qb:.1f}")

    # Phrase boundaries (8 bars = 32 beats) in each track.
    fa, _ = phrase_phase(a, ga)
    fb, _ = phrase_phase(b, gb)
    results = []
    for variant, overlap in (("equal-power", 64), ("bass-swap", 64)):
        # Exit on the last phrase start that leaves `overlap` beats; entry on the first incoming
        # phrase start after its leading silence.
        exit_idx = max(i for i in range(fa, len(ga), 32) if i + overlap < len(ga))
        silence = leading_silence(b)
        entry_idx = next(i for i in range(fb, len(gb), 32) if gb[i] >= silence)
        exit_t, entry_t = ga[exit_idx], gb[entry_idx]
        # Kick attacks around the overlap, in each track's own time.
        ov_a = ga[exit_idx:exit_idx + overlap]
        ov_b = gb[entry_idx:entry_idx + overlap]
        att_a, _ = kick_attacks(ea, ov_a)
        att_b, _ = kick_attacks(eb, ov_b)
        # Global calibration: each track's typical kick-attack offset from its grid.
        cal_a = np.nanmedian(kick_attacks(ea, ga)[0] - ga)
        cal_b = np.nanmedian(kick_attacks(eb, gb)[0] - gb)
        # Static placement aligns attacks (not grids); per-beat nudging follows the music.
        base = (exit_t + cal_a) - (entry_t + cal_b)    # output time of incoming = its time + base
        per_beat = (att_a - exit_t) - (att_b - entry_t) - (cal_a - cal_b)
        exit_s = int(round(exit_t * SR))
        n_total = exit_s + (len(b) - int(round(entry_t * SR))) + int(abs(cal_a - cal_b) * SR) + SR
        # Incoming placed on the output timeline.
        shift = int(round((exit_t + (cal_a - cal_b) - entry_t) * SR))
        inc = np.zeros((n_total, 2), np.float32)
        s0 = max(0, shift)
        inc[s0:s0 + len(b) - max(0, -shift)] = b[max(0, -shift):max(0, -shift) + n_total - s0][:n_total - s0]
        beat_out_times = ov_a
        delay = nudge_curve(per_beat, beat_out_times, n_total, hold_start=0.0)
        inc_locked = apply_delay(inc, delay)
        # Envelopes over the overlap (output time = outgoing time).
        n_ov = int(round(overlap * pa * SR))
        mix = np.zeros((n_total, 2), np.float32)
        mix[:exit_s] = a[:exit_s]
        beat = np.arange(n_ov) / (pa * SR)
        q = overlap / 4
        if variant == "equal-power":
            p = beat / overlap
            ang = np.where(p < 1 / 3, smooth(p * 3) * np.pi / 4,
                  np.where(p < 2 / 3, np.pi / 4, np.pi / 4 + smooth((p - 2 / 3) * 3) * np.pi / 4))
            out_seg = a[exit_s:exit_s + n_ov]
            mix[exit_s:exit_s + len(out_seg)] += out_seg * np.cos(ang)[:len(out_seg), None]
            g_in = np.concatenate([np.sin(ang), np.ones(n_total - exit_s - n_ov)])
            mix[exit_s:] += inc_locked[exit_s:] * g_in[:n_total - exit_s, None] * gain
            marks = [("blend starts (phrase start)", exit_t), ("both equal", exit_t + overlap * pa / 3),
                     ("midpoint", exit_t + overlap * pa / 2), ("outgoing fading", exit_t + 2 * overlap * pa / 3),
                     ("blend ends", exit_t + overlap * pa)]
        else:
            from blend import decode as dec
            a_lo, a_hi = dec(a_path, band="low"), dec(a_path, band="high")
            b_lo, b_hi = dec(b_path, ratio, "low"), dec(b_path, ratio, "high")
            def place(x):
                y = np.zeros((n_total, 2), np.float32)
                y[s0:s0 + len(x) - max(0, -shift)] = x[max(0, -shift):max(0, -shift) + n_total - s0][:n_total - s0]
                return apply_delay(y, delay)
            bl, bh = place(b_lo), place(b_hi)
            in_hi = smooth(beat / q)
            swap = smooth((beat - 2 * q) / 1.0)
            out_hi = 1 - smooth((beat - 3 * q) / q)
            seg = slice(exit_s, exit_s + n_ov)
            m = len(a_lo[seg])
            mix[exit_s:exit_s + m] += a_lo[seg] * (1 - swap)[:m, None] + a_hi[seg] * out_hi[:m, None]
            mix[seg] += (bl[seg] * swap[:, None] + bh[seg] * in_hi[:, None]) * gain
            mix[exit_s + n_ov:] += (bl[exit_s + n_ov:] + bh[exit_s + n_ov:]) * gain
            marks = [("blend starts: incoming highs in (phrase start)", exit_t),
                     ("incoming highs full", exit_t + overlap * pa / 4),
                     ("bass swap on the phrase downbeat (midpoint)", exit_t + overlap * pa / 2),
                     ("outgoing highs fading", exit_t + 3 * overlap * pa / 4),
                     ("blend ends", exit_t + overlap * pa)]
        # Measured flam on the final stems over the overlap (outgoing vs locked incoming).
        ov_out_beats = ga[exit_idx:exit_idx + overlap]
        env_inc_out = low_env(inc_locked[:min(n_total, exit_s + n_ov + SR)])
        fl_locked = flam_ms(ea, env_inc_out, ov_out_beats)
        env_inc_static = low_env(inc[:min(n_total, exit_s + n_ov + SR)])
        fl_static = flam_ms(ea, env_inc_static, ov_out_beats)
        name = f"{label}__LOCKED__{variant}__{overlap}beats.wav"
        path = os.path.abspath(os.path.join(out_dir, name))
        write_wav(path, mix[:np.max(np.nonzero(np.abs(mix).sum(axis=1))) + 1])
        print(f"  {name}: flam |median| {fl_locked[0]:.1f} ms, p90 {fl_locked[1]:.1f} ms over {fl_locked[2]} "
              f"beats (attack-aligned, before nudging: {fl_static[0]:.1f}/{fl_static[1]:.1f} ms); "
              f"nudge range {np.min(delay)*1000:+.1f}…{np.max(delay)*1000:+.1f} ms; "
              f"blend {mmss(exit_t)}–{mmss(exit_t + overlap * pa)}")
        results.append({"file": path, "label": label, "variant": variant, "overlapBeats": overlap,
                        "flamMedianMs": fl_locked[0], "flamP90Ms": fl_locked[1], "beatsMeasured": fl_locked[2],
                        "flamBeforeNudgeMs": fl_static[0], "marks": marks,
                        "outgoing": f"{A['title']} — {A['artist']} ({60 / pa:.2f} BPM measured)",
                        "incoming": f"{B['title']} — {B['artist']} ({60 / pb:.2f} BPM, played at x{ratio:.4f})"})
    return results


def main():
    cand, out_dir, cache = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    tracks = json.load(open(cand))
    results = []
    for spec in sys.argv[4:]:
        a, b, label = spec.split(":")
        results += render((a, b, label), tracks, cache, out_dir)
    json.dump(results, open(os.path.join(out_dir, "summary.json"), "w"), indent=1, default=float)


if __name__ == "__main__":
    main()
