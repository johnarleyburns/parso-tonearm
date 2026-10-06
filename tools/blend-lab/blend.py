#!/usr/bin/env python3
"""Offline blend lab: renders Platterhead-style transitions to WAV so they can be judged by ear
before the iOS executor changes. Uses the app's own beat grids (Mood Starter prep records,
decoded by decode-prep) and the real tracks.

Every variant is rendered sample-accurately, so what you hear is the *plan* (grid, exit/entry,
tempo match, gain curve), free of AVPlayer timing problems. If a variant sounds right here and
wrong on the phone, the executor is at fault; if it sounds wrong here, the plan is.

Usage: blend.py <candidates.json> <out-dir> <cache-dir> <from-id>:<to-id>[:label] ...
Needs: python3 + numpy, ffmpeg (atempo, acrossover).
"""
import json, os, subprocess, sys, urllib.request, wave
import numpy as np

SR = 44_100
# Both tracks play in full: the outgoing one from its start to the blend, the incoming one from
# the blend to its end, so the transition can be heard in context.


# ---------------------------------------------------------------- audio io

def fetch(track, cache, tid):
    path = os.path.join(cache, f"{tid}.mp3")
    if not os.path.exists(path):
        print(f"  downloading {tid} — {track['title']}")
        urllib.request.urlretrieve(track["url"], path)
    return path


def decode(path, tempo=1.0, band=None):
    """Stereo float32 at SR. tempo>1 speeds up with pitch kept (ffmpeg atempo).
    band: None, 'low' or 'high' — a 4th-order Linkwitz-Riley split at 150 Hz (bands sum flat)."""
    chain = f"atempo={tempo:.6f}" if abs(tempo - 1) > 1e-6 else "anull"
    if band:
        keep, drop = ("lo", "hi") if band == "low" else ("hi", "lo")
        graph = f"[0:a]{chain},acrossover=split=150:order=4th[lo][hi];[{drop}]anullsink"
        cmd = ["ffmpeg", "-v", "error", "-i", path, "-filter_complex", graph,
               "-map", f"[{keep}]", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"]
    else:
        cmd = ["ffmpeg", "-v", "error", "-i", path, "-af", chain, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()


def mmss(seconds):
    return f"{int(seconds // 60)}:{seconds % 60:04.1f}"


def write_wav(path, audio):
    peak = float(np.max(np.abs(audio))) or 1.0
    if peak > 0.98:
        audio = audio * (0.98 / peak)
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return peak


def rms_db(audio):
    return 20 * np.log10(np.sqrt(np.mean(audio.astype(np.float64) ** 2)) + 1e-12)


def leading_silence(audio, threshold_db=-50):
    frame = SR // 20
    mono = np.abs(audio).mean(axis=1)
    level = 10 ** (threshold_db / 20)
    for i in range(0, len(mono) - frame, frame):
        if np.sqrt(np.mean(mono[i:i + frame] ** 2)) >= level:
            return i / SR
    return 0.0


# ---------------------------------------------------------------- grids

class Grid:
    """Beats and downbeats in source seconds."""
    def __init__(self, beats, downbeats, bpm, kind):
        self.beats = np.asarray(beats, float)
        self.downbeats = np.asarray(downbeats, float)
        self.bpm = bpm
        self.kind = kind

    def scaled(self, factor):
        """Times after the audio is sped up by `factor`."""
        return Grid(self.beats / factor, self.downbeats / factor, self.bpm * factor, self.kind)


# The analyser's beat times and tempo run fast by exactly 441/440 on every track measured
# (folding the kicks onto the analysed period smears; folding onto period x 441/440 is sharp, and
# the kick-to-grid offset is then constant from the first beat to the last). See README.md.
ANALYSER_TIME_SCALE = 441 / 440


def raw_grid(t):
    return Grid(t["beats"], t["downbeats"], t["bpm"], "raw")


def corrected_grid(t, duration):
    """The analyser's grid with its 441/440 time-scale error removed, then regularised."""
    fixed = dict(t, beats=[b * ANALYSER_TIME_SCALE for b in t["beats"]],
                 downbeats=[b * ANALYSER_TIME_SCALE for b in t["downbeats"]],
                 bpm=t["bpm"] / ANALYSER_TIME_SCALE)
    g = fitted_grid(fixed, duration)
    g.kind = "corrected"
    return g


def fitted_grid(t, duration):
    """A perfectly regular grid from the analysed tempo, phase-locked to the detected beats with
    outliers ignored, and bar-aligned to the beat index most downbeats agree on."""
    beats = np.asarray(t["beats"], float)
    period = 60.0 / t["bpm"]
    # Circular mean of beat phases, then two rounds of trimmed least squares for period + offset.
    phases = (beats % period) / period * 2 * np.pi
    t0 = (np.angle(np.mean(np.exp(1j * phases))) % (2 * np.pi)) / (2 * np.pi) * period
    for _ in range(3):
        idx = np.round((beats - t0) / period)
        resid = beats - (t0 + idx * period)
        keep = np.abs(resid) < max(0.02, 2.5 * np.median(np.abs(resid)))
        if keep.sum() < 8:
            break
        A = np.vstack([idx[keep], np.ones(keep.sum())]).T
        (period, t0), *_ = np.linalg.lstsq(A, beats[keep], rcond=None)
    n0 = int(np.floor(-t0 / period))
    grid = t0 + period * np.arange(n0, int((duration - t0) / period) + 1)
    grid = grid[(grid >= 0) & (grid <= duration)]
    # Bar phase: which beat index mod 4 the detected downbeats mostly fall on.
    downs = np.asarray(t["downbeats"], float)
    first_idx = np.round((grid[0] - t0) / period)
    if len(downs):
        d_idx = (np.round((downs - t0) / period) - first_idx).astype(int) % 4
        bar_phase = int(np.bincount(d_idx, minlength=4).argmax())
    else:
        bar_phase = 0
    return Grid(grid, grid[bar_phase::4], 60.0 / period, "fitted")


# ---------------------------------------------------------------- plans + curves

def smooth(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def envelopes(variant, n, beat_len_samples, overlap_beats):
    """Per-sample gains over the overlap: returns dict of arrays for out/in (or out_lo/out_hi/in_lo/in_hi)."""
    p = np.arange(n) / max(n - 1, 1)
    if variant == "shipped-linear":            # what shipped before 2026-10-04: both at 1.0 mid-phrase
        inc = np.clip(p * 3, 0, 1)
        out = np.clip((1 - p) * 3, 0, 1)
        return {"out": out, "in": inc}
    if variant == "equal-power":                # the 2026-10-04 iOS change
        a = np.where(p < 1 / 3, smooth(p * 3) * np.pi / 4,
             np.where(p < 2 / 3, np.pi / 4, np.pi / 4 + smooth((p - 2 / 3) * 3) * np.pi / 4))
        return {"out": np.cos(a), "in": np.sin(a)}
    if variant == "bass-swap":                  # DJ practice: incoming without bass, swap on a downbeat
        beat = np.arange(n) / beat_len_samples
        q = overlap_beats / 4                   # four phrases
        in_hi = smooth(beat / q)                # phrase 1: incoming highs in
        swap = smooth((beat - 2 * q) / 1.0)     # bass swap over one beat at the start of phrase 3
        out_lo, in_lo = 1 - swap, swap
        out_hi = 1 - smooth((beat - 3 * q) / q)  # phrase 4: outgoing highs out
        return {"out_lo": out_lo, "out_hi": out_hi, "in_lo": in_lo, "in_hi": in_hi}
    raise ValueError(variant)


def render(pair, tracks, cache, out_dir, variants):
    a_id, b_id, label = pair
    A, B = tracks[a_id], tracks[b_id]
    a_path, b_path = fetch(A, cache, a_id), fetch(B, cache, b_id)
    ratio = A["bpm"] / B["bpm"]                 # incoming plays at the outgoing tempo
    a_full = decode(a_path)
    b_src = decode(b_path)
    b_full = decode(b_path, tempo=ratio)
    measured = len(b_src) / len(b_full)         # actual stretch, for exact grid scaling
    a_dur = len(a_full) / SR
    gain_db = rms_db(a_full) - rms_db(b_full)  # match incoming loudness to outgoing
    gain = 10 ** (gain_db / 20)
    print(f"\n{label}: {A['title']} ({A['bpm']:.2f}) -> {B['title']} ({B['bpm']:.2f}), "
          f"stretch x{ratio:.4f} (measured x{measured:.4f}), gain {gain_db:+.1f} dB")
    bands = {}
    results = []
    for variant, grid_kind, overlap_beats in variants:
        make = {"raw": lambda T, d: raw_grid(T), "fitted": fitted_grid, "corrected": corrected_grid}[grid_kind]
        ga, gb_src = make(A, a_dur), make(B, len(b_src) / SR)
        gb = gb_src.scaled(measured)
        period = 60.0 / ga.bpm
        # Exit: the app's rule — last downbeat at least `overlap` beats before the end.
        blend_start = max(0.0, a_dur - overlap_beats * period)
        exits = ga.downbeats[ga.downbeats <= blend_start]
        exit_t = exits[-1] if len(exits) else blend_start
        # Entry: first downbeat after leading silence (raw grid: first *beat*, as the old planner did).
        silence = leading_silence(b_full)
        pool = gb.beats if (grid_kind == "raw" and variant == "shipped-linear") else gb.downbeats
        entries = pool[pool >= silence]
        entry_t = entries[0] if len(entries) else silence
        n_overlap = int(round(overlap_beats * period * SR))
        start = 0
        exit_s, entry_s = int(round(exit_t * SR)), int(round(entry_t * SR))
        tail_end = len(b_full)
        total = (exit_s - start) + (tail_end - entry_s)
        mix = np.zeros((total, 2), np.float32)
        pre = exit_s - start
        out_seg_len = min(n_overlap, len(a_full) - exit_s)
        env = envelopes(variant, n_overlap, period * SR, overlap_beats)
        mix[:pre] = a_full[start:exit_s]
        if "out" in env:
            mix[pre:pre + out_seg_len] += a_full[exit_s:exit_s + out_seg_len] * env["out"][:out_seg_len, None]
        else:
            if "a_lo" not in bands:
                bands["a_lo"], bands["a_hi"] = decode(a_path, band="low"), decode(a_path, band="high")
                bands["b_lo"], bands["b_hi"] = decode(b_path, ratio, "low"), decode(b_path, ratio, "high")
            for key, e in (("a_lo", env["out_lo"]), ("a_hi", env["out_hi"])):
                mix[pre:pre + out_seg_len] += bands[key][exit_s:exit_s + out_seg_len] * e[:out_seg_len, None]
        inc_len = tail_end - entry_s
        inc = np.zeros((inc_len, 2), np.float32)
        ov = min(n_overlap, inc_len)
        if "in" in env:
            inc[:ov] = b_full[entry_s:entry_s + ov] * env["in"][:ov, None]
        else:
            for key, e in (("b_lo", env["in_lo"]), ("b_hi", env["in_hi"])):
                seg = bands[key][entry_s:entry_s + ov]
                inc[:len(seg)] += seg * e[:len(seg), None]
        inc[ov:] = b_full[entry_s + ov:tail_end]
        mix[pre:pre + inc_len] += inc * gain
        # How far the two grids disagree during the overlap (what you hear as flamming kicks).
        a_beats = ga.beats[(ga.beats >= exit_t) & (ga.beats < exit_t + overlap_beats * period)] - exit_t
        b_beats = gb.beats[(gb.beats >= entry_t) & (gb.beats < entry_t + overlap_beats * period)] - entry_t
        offs = [np.min(np.abs(b_beats - t)) * 1000 for t in a_beats] if len(b_beats) else [np.nan]
        name = f"{label}__{variant}__{grid_kind}-grid__{overlap_beats}beats.wav"
        peak = write_wav(os.path.join(out_dir, name), mix)
        lag_a = kick_lag_ms(a_full, ga.beats[(ga.beats >= exit_t) & (ga.beats < exit_t + overlap_beats * period)])
        lag_b = kick_lag_ms(b_full, gb.beats[(gb.beats >= entry_t) & (gb.beats < entry_t + overlap_beats * period)])
        kick_ms, contrast = lag_b - lag_a, 0.0
        t0 = pre / SR
        span = n_overlap / SR
        if variant == "bass-swap":
            marks = [("blend starts: incoming highs fade in (no bass yet)", t0),
                     ("incoming highs at full, both tracks playing", t0 + span / 4),
                     ("bass swap on the downbeat (midpoint)", t0 + span / 2),
                     ("outgoing highs start fading out", t0 + 3 * span / 4),
                     ("blend ends: incoming track alone", t0 + span)]
        else:
            marks = [("blend starts: incoming fades in", t0),
                     ("both tracks at equal level", t0 + span / 3),
                     ("midpoint", t0 + span / 2),
                     ("outgoing starts fading out", t0 + 2 * span / 3),
                     ("blend ends: incoming track alone", t0 + span)]
        results.append({"file": os.path.abspath(os.path.join(out_dir, name)), "label": label,
                        "variant": variant, "grid": grid_kind, "overlapBeats": overlap_beats,
                        "outgoing": f"{A['title']} — {A['artist']} ({A['bpm'] / ANALYSER_TIME_SCALE:.1f} BPM)",
                        "incoming": f"{B['title']} — {B['artist']} ({B['bpm'] / ANALYSER_TIME_SCALE:.1f} BPM, "
                                    f"played at x{ratio:.3f})",
                        "kickOffsetMs": kick_ms, "marks": marks, "lengthSec": len(mix) / SR})
        print(f"  {name}: grid offset median {np.median(offs):.0f} ms, p90 {np.percentile(offs, 90):.0f} ms; "
              f"kicks: incoming {kick_ms:+.0f} ms vs outgoing (measured from each track's own kicks); "
              f"blend {mmss(pre / SR)}–{mmss((pre + n_overlap) / SR)}")
    return results


def onset_env(audio, hop=SR // 200):
    """Low-frequency onset strength at 5 ms hops: energy below ~150 Hz (FFT band-limit), rectified flux."""
    mono = audio.mean(axis=1).astype(np.float64)
    spec = np.fft.rfft(mono)
    freqs = np.fft.rfftfreq(len(mono), 1 / SR)
    spec[(freqs < 35) | (freqs > 150)] = 0
    low = np.fft.irfft(spec, len(mono))
    frames = len(low) // hop
    energy = np.sqrt(np.mean(low[:frames * hop].reshape(frames, hop) ** 2, axis=1))
    flux = np.maximum(0, np.diff(energy, prepend=energy[0]))
    return flux / (np.max(flux) + 1e-12)


def kick_offset_ms(a_seg, b_seg, beat_seconds):
    """Lag (ms) of the incoming kicks relative to the outgoing ones, from cross-correlating their
    low-band onsets within ±half a beat. 0 = kicks land together; positive = incoming late."""
    n = min(len(a_seg), len(b_seg))
    if n < SR * 4:
        return float("nan"), 0.0
    ea, eb = onset_env(a_seg[:n]), onset_env(b_seg[:n])
    max_lag = int(beat_seconds / 2 * 200)
    lags = np.arange(-max_lag, max_lag + 1)
    scores = [np.dot(ea[max(0, -l):len(ea) - max(0, l)], eb[max(0, l):len(eb) - max(0, -l)]) for l in lags]
    best = int(np.argmax(scores))
    contrast = scores[best] / (np.median(scores) + 1e-12)
    return lags[best] * 5.0, contrast


def kick_lag_ms(audio, beats):
    """Median lag (ms) from grid beats to the strongest low-band onset within ±150 ms.
    Absolute values include a constant decoder/onset offset; the difference between two tracks
    is what you hear as flamming kicks."""
    env = onset_env(audio, hop=SR // 1000)       # 1 ms hops
    lags = []
    for b in beats:
        i = int(round(b * 1000)); w = env[max(0, i - 150):i + 151]
        if len(w) == 301 and w.max() > 0.2: lags.append(int(np.argmax(w)) - 150)
    return float(np.median(lags)) if lags else float("nan")


def grid_check(tid, tracks, cache, out_dir):
    """30 s from the middle of a track with clicks: raw grid in one file, fitted grid in another.
    Downbeats click higher. If the raw clicks wander off the kick, the analyser's grid is the problem."""
    T = tracks[tid]
    audio = decode(fetch(T, cache, tid))
    dur = len(audio) / SR
    s, e = dur / 2 - 15, dur / 2 + 15
    for grid in (raw_grid(T), corrected_grid(T, dur)):
        clip = audio[int(s * SR):int(e * SR)].copy() * 0.7
        downs = set(np.round(grid.downbeats, 3))
        for b in grid.beats[(grid.beats >= s) & (grid.beats < e)]:
            f = 1760 if round(b, 3) in downs else 1100
            i = int((b - s) * SR)
            k = np.arange(min(int(0.03 * SR), len(clip) - i))
            clip[i:i + len(k)] += (0.5 * np.sin(2 * np.pi * f * k / SR) * np.exp(-k / (0.006 * SR)))[:, None]
        write_wav(os.path.join(out_dir, f"gridcheck__{tid}__{grid.kind}.wav"), clip)


LISTEN_FOR = {
    "shipped-linear": "The plan as it shipped: the analyser's grid, unchanged. Expect kicks that don't line "
                      "up (a galloping double kick, or a smear) and a jump in loudness when both tracks are "
                      "at full level. This is the reference for what is broken.",
    "equal-power": "Grid corrected. From the blend start the incoming kick should land exactly on the "
                   "outgoing kick: one kick, not two. The level should stay even the whole way, with no "
                   "bump or dip. Listen at the midpoint for any flam (a double hit 20–50 ms apart).",
    "bass-swap": "Grid corrected, DJ style. The incoming track comes in with its low end removed: you hear "
                 "its hats, synths and the click of its kick, riding on the outgoing kick and bassline. At "
                 "the midpoint the basses swap on a downbeat. That swap should feel like a clean drop, not "
                 "a gap or a doubled, booming bass.",
}


def write_guide(results, out_dir):
    lines = ["# Blend listening guide", "",
             "Each file is two full tracks: the outgoing track from its start, the blend, then the incoming "
             "track to its end (it stays at the outgoing tempo after the blend). Times are elapsed time in "
             "the file. Jump to the blend start minus ~20 s and listen through the blend end.", ""]
    for label in dict.fromkeys(r["label"] for r in results):
        group = [r for r in results if r["label"] == label]
        lines += [f"## {label}", "", f"- Outgoing: {group[0]['outgoing']}", f"- Incoming: {group[0]['incoming']}", ""]
        for r in group:
            lines += [f"### {r['variant']} · {r['grid']} grid · {r['overlapBeats']} beats",
                      f"`{r['file']}`  ({mmss(r['lengthSec'])} long; measured kick offset {r['kickOffsetMs']:+.0f} ms)", "",
                      LISTEN_FOR[r["variant"]], ""]
            lines += [f"- **{mmss(t)}** — {what}" for what, t in r["marks"]] + [""]
    path = os.path.join(out_dir, "LISTENING-GUIDE.md")
    open(path, "w").write("\n".join(lines))
    return os.path.abspath(path)


def main():
    cand, out_dir, cache = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True); os.makedirs(cache, exist_ok=True)
    tracks = json.load(open(cand))
    variants = [("shipped-linear", "raw", 96),       # the plan as shipped: analyser grid, 96 beats
                ("equal-power", "corrected", 96),    # grid fixed (441/440, regular), equal-power, 96 beats
                ("bass-swap", "corrected", 64)]      # grid fixed, DJ-style 16 bars with a bass swap
    results = []
    for spec in sys.argv[4:]:
        a, b, *rest = spec.split(":")
        results += render((a, b, rest[0] if rest else f"{a}-{b}"), tracks, cache, out_dir, variants)
    json.dump(results, open(os.path.join(out_dir, "summary.json"), "w"), indent=1)
    print("\nguide:", write_guide(results, out_dir))


if __name__ == "__main__":
    main()
