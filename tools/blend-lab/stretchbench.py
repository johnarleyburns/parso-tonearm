#!/usr/bin/env python3
"""Kick-timing benchmark for keylocked stretchers (2026-10-08), with the validated meter.

Reference: a plain resample at the same ratio (pitch moves, timing is exact). For every 8-beat
window where the beat is readable, the stretcher's beat phase minus the reference's: the median is
the stretcher's constant latency (compensable), the spread around it is jitter (flam).

Usage: stretchbench.py <tracks.json> <cache> <track-id>:<ratio>:<band> ...
"""
import json, os, subprocess, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from blend import SR, decode, fetch
import meter

SCRATCH = os.environ.get("SCRATCH", "/tmp")
SS = os.path.join(SCRATCH, "ss_cli"); BUNGEE = os.path.join(SCRATCH, "bungee_cli")
APPLE = os.path.join(os.path.dirname(__file__), "cache", "apple-stretch")


def f32(path, wav):
    raw = wav[:-4] + ".f32"
    if not os.path.exists(raw):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-f", "f32le", "-ac", "2", "-ar", str(SR), raw], check=True)
    return raw


def load_f32(path):
    return np.fromfile(path, "<f4").reshape(-1, 2)


def render(kind, wav, ratio, cache):
    base = os.path.splitext(wav)[0]
    out = f"{base}__{kind}_x{ratio:.6f}"
    if kind == "resample":
        # exact timing: output sample i reads input position i * ratio (linear interpolation;
        # aliasing doesn't matter for beat timing, and ffmpeg asetrate only takes whole rates)
        x = decode(wav)
        pos = np.arange(int(len(x) / ratio)) * ratio
        return np.stack([np.interp(pos, np.arange(len(x)), x[:, c]) for c in range(2)], axis=1)
    if kind == "rubberband-R2":
        o = out + ".wav"
        if not os.path.exists(o):
            subprocess.run(["rubberband", "-2", "-c", "6", "-T", f"{ratio:.6f}", wav, o], check=True, capture_output=True)
        return decode(o)
    if kind == "atempo":
        return decode(wav, tempo=ratio)
    if kind.startswith("signalsmith"):
        o = out + ".f32"
        extra = {"signalsmith": [], "signalsmith-60ms": ["60", "4"], "signalsmith-40ms": ["40", "6"]}[kind]
        if not os.path.exists(o):
            subprocess.run([SS, f32(o, wav), o, f"{ratio:.6f}"] + extra, check=True)
        return load_f32(o)
    if kind.startswith("bungee"):
        o = out + ".wav"
        extra = {"bungee": [], "bungee-short": ["--grain", "-1"]}[kind]
        if not os.path.exists(o):
            subprocess.run([BUNGEE, "-s", f"{ratio:.6f}"] + extra + [wav, o], check=True, capture_output=True)
        return decode(o)
    if kind.startswith("apple"):
        o = out + ".caf"
        extra = {"apple": [], "apple-ov32": ["32"]}[kind]
        if not os.path.exists(o):
            subprocess.run([APPLE, wav, o, f"{ratio:.6f}"] + extra, check=True, capture_output=True)
        return decode(o)
    raise ValueError(kind)


KINDS = ["rubberband-R2", "signalsmith", "signalsmith-60ms", "signalsmith-40ms", "bungee", "bungee-short",
         "apple", "apple-ov32", "atempo"]


def main():
    tracks = json.load(open(sys.argv[1])); cache = sys.argv[2]
    rows = {}
    for spec in sys.argv[3:]:
        tid, ratio, band = spec.split(":"); ratio = float(ratio)
        T = tracks[tid]
        mp3 = fetch(T, cache, tid)
        wav = os.path.join(cache, f"{tid}.wav")
        if not os.path.exists(wav):
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mp3, "-ar", str(SR), wav], check=True)
        ref = render("resample", wav, ratio, cache)
        p = 60 / (round(T["bpm"]) * ratio)
        fr = meter.flux(ref, band)
        dur = len(ref) / SR
        wins = np.arange(0, dur - 8 * p, 8 * p)
        rp = [meter.fold(fr, t, t + 8 * p, p) for t in wins]
        print(f"\n{T['title'][:30]} x{ratio} band {band} ({sum(s >= 0.15 for _, s in rp)} readable 8-beat windows)")
        for kind in KINDS:
            try:
                y = render(kind, wav, ratio, cache)
            except Exception as e:  # noqa: BLE001
                print(f"  {kind:18s} failed: {e}"); continue
            fy = meter.flux(y, band)
            d = []
            for t, (pr, sr) in zip(wins, rp):
                py, sy = meter.fold(fy, t, t + 8 * p, p)
                if sr >= 0.15 and sy >= 0.15:
                    d.append(meter.wrap(py - pr, p))
            d = np.array(d) * 1000
            lat = np.median(d); j = np.abs(d - lat)
            rows.setdefault(kind, []).append((np.percentile(j, 90), j.max()))
            print(f"  {kind:18s} latency {lat:+7.2f} ms   jitter p50 {np.median(j):5.2f}  p90 {np.percentile(j, 90):5.2f}  max {j.max():6.2f} ms")
    print("\nall tracks: worst p90 / worst max jitter (ms)")
    for kind, v in rows.items():
        print(f"  {kind:18s} {max(a for a, _ in v):5.2f} / {max(b for _, b in v):6.2f}")


if __name__ == "__main__":
    main()
