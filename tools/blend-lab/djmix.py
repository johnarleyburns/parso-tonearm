#!/usr/bin/env python3
"""DJ-planned blends (2026-10-08): the bass swap lands on the incoming track's drop.

1. Structure per track (structure.py): drops and bass exits, snapped to the track's bar phase
   (the 4-beat phase most events share), and its phrase phase (32 beats).
2. Incoming swap point: its first drop with at least 8 bars of track before it; if its bass is in
   from the start, the first phrase line 8 bars in. The incoming always starts 8 bars before it.
3. Outgoing swap point, best first:
     double drop  an outgoing drop in its second half: both tracks drop together;
     bass exit    the outgoing's breakdown or outro starts as the incoming's bass arrives;
     phrase line  the latest phrase line that leaves 8 bars after it.
4. Placement by the groove (groove.py): the outgoing averaged over the 128 beats before the blend,
   the incoming over the 128 after it; the incoming moves so the grooves line up. A candidate is
   used only if at least 3 of the 4 bands' onsets agree with that lag (techno and deep house often
   don't: then the next candidate). The old fold-angle meter (meter.py) read bass, not kicks.
5. Bass-swap mix (lock.mix_variants), 64 beats: incoming highs in over 4 bars, basses swap on the
   downbeat at bar 8 (the swap point), outgoing highs out over the last 4 bars.
   No candidate agrees: phrase cut (align.py).

Usage: djmix.py <tracks.json> <out-dir> <cache> <from>:<to>:<label> ...
"""
import json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from blend import SR, decode, fetch, rms_db, leading_silence, mmss  # noqa: E402
import lock  # noqa: E402
lock.VARIANTS = ("bass-swap",)
from lock import low_env, audio_period, regular_grid, place, mix_variants  # noqa: E402
import align  # noqa: E402
from align import stretch  # noqa: E402
import groove  # noqa: E402
from structure import Structure  # noqa: E402

OVERLAP = 64
GROOVE_BEATS = 128      # ~1 minute each side
HALF = OVERLAP // 2


def phase_of(events, weights, mod):
    """The index phase (mod `mod`) most events share, weighted by their step size."""
    score = np.zeros(mod)
    for i, w in zip(events, weights):
        score[i % mod] += w
    return int(np.argmax(score)) if len(events) else 0


def snap(i, ph, mod=4):
    return i + ((ph - i + mod // 2) % mod) - mod // 2


class Track:
    def __init__(self, audio, grid):
        self.audio, self.grid = audio, grid
        s = Structure(audio, grid)
        ev = s.drops + s.exits
        w = [s.drop_step[i] for i in s.drops] + [s.exit_step[i] for i in s.exits]
        self.bar = phase_of(ev, w, 4)
        self.phrase = phase_of([snap(i, self.bar) for i in ev], w, 32)
        self.drops = sorted({snap(i, self.bar) for i in s.drops})
        self.exits = sorted({snap(i, self.bar) for i in s.exits})
        self.db = s.db
        self.n = len(grid)


def bass_from_start(T, silence_beat):
    """True when the track's bass is in from its first bars (no drop to wait for)."""
    first = T.db[silence_beat:silence_beat + 16]
    return len(first) > 0 and np.median(first) >= np.median(T.db) - 6


def incoming_points(B, silence_beat):
    """Swap points on the incoming track, best first: its first drop (an intro of at least 4 bars;
    if it is shorter than 8 the incoming starts a little into the blend), a phrase line 8 bars in
    when its bass is in from the start, its later drops in its first half, then phrase lines."""
    pts = []
    drops = [d for d in B.drops if d - 16 >= silence_beat]
    if drops:
        pts.append((drops[0], "its first drop"))
    phrases = [i for i in range(B.phrase, B.n // 2, 32) if i - 16 >= silence_beat]
    if bass_from_start(B, silence_beat) and phrases:
        pts.append((next((i for i in phrases if i - HALF >= silence_beat), phrases[0]),
                    "a phrase line (its bass is in from the start)"))
    pts += [(d, "a later drop") for d in drops[1:] if d < B.n // 2]
    pts += [(i, "a phrase line") for i in phrases]
    seen, out = set(), []
    for i, why in pts:
        if i not in seen and i + HALF < B.n:
            seen.add(i); out.append((i, why))
    return out


def outgoing_points(A):
    """Swap points on the outgoing track, best first within each style, latest first."""
    ok = lambda i: i - HALF >= 0 and i + HALF < A.n - 1   # noqa: E731
    half = A.n // 2
    pts = [(d, "double drop") for d in reversed(A.drops) if d >= half and ok(d)]
    pts += [(e, "bass exit") for e in reversed(A.exits) if e >= half and ok(e)]
    pts += [(i, "phrase line") for i in reversed(range(A.phrase, A.n, 32)) if i >= half and ok(i)]
    return pts


def render(spec, tracks, cache, out_dir):
    a_id, b_id, label = spec
    TA, TB = tracks[a_id], tracks[b_id]
    a_path, b_path = fetch(TA, cache, a_id), fetch(TB, cache, b_id)
    a = decode(a_path); b_src = decode(b_path)
    pa, pha, _ = audio_period(low_env(a), TA["bpm"])
    pb, phb, _ = audio_period(low_env(b_src), TB["bpm"])
    ratio = pb / pa
    b_stretched = stretch(b_path, ratio, cache)
    b = decode(b_stretched)
    A = Track(a, regular_grid(pa, pha, len(a) / SR))
    B = Track(b, regular_grid(pb / ratio, phb / ratio, len(b) / SR))
    gain = 10 ** ((rms_db(a) - rms_db(b)) / 20)
    silence_beat = int(np.searchsorted(B.grid, leading_silence(b)))
    bands_a, bands_b = groove.split(a), groove.split(b)
    why_not = []
    print(f"\n{label}: {TA['title']} -> {TB['title']}  {60/pa:.2f} -> {60/pb:.2f} BPM, x{ratio:.5f}")
    print(f"  outgoing drops {[mmss(A.grid[i]) for i in A.drops]}, bass exits {[mmss(A.grid[i]) for i in A.exits]}")
    print(f"  incoming drops {[mmss(B.grid[i]) for i in B.drops]}, bass exits {[mmss(B.grid[i]) for i in B.exits]}")

    results, done_styles = [], set()
    for sa, style in outgoing_points(A):
        kind = "double-drop" if style == "double drop" else "bass-swap"
        if kind in done_styles:
            continue
        for sb, why in incoming_points(B, silence_beat):
            start_a, start_b = A.grid[sa - HALF], B.grid[sb] - HALF * pa      # may be < 0: short intro
            end_b = B.grid[sb + HALF] if sb + HALF < B.n else B.grid[-1]
            if "bass-swap" in done_styles and kind == "bass-swap":
                break
            # Placement by the groove (groove.py): the outgoing over the GROOVE_BEATS before the
            # blend, the incoming over the GROOVE_BEATS after it (a whole number of beats apart).
            shift_t = start_a - start_b
            ta = start_a - GROOVE_BEATS * pa
            tb = start_a + OVERLAP * pa
            g = groove.offset(bands_a, bands_b, ta, tb, GROOVE_BEATS, pa, shift_t)
            if g is None or g[2] < groove.MIN_AGREE:
                why_not.append(f"{style} {mmss(A.grid[sa])} x {mmss(B.grid[sb])}: " +
                               ("window off the track" if g is None else
                                "bands disagree " + " ".join(f"{o*1000:+.0f}" for o in g[1]) +
                                f" vs groove {g[0]*1000:+.0f} ms"))
                continue
            delta = -g[0]
            shift_t += delta
            reading = "groove"
            onsets = " ".join(f"{o*1000:+.0f}" for o in g[1])
            shift = int(round(shift_t * SR)); n = len(b) + shift
            exit_s = int(round(start_a * SR))
            name = f"{label}__{kind}"
            res = mix_variants(name, "dj", TA, TB, a, a_path, b_stretched, place(b, shift, n), shift, n, np.zeros(n),
                               start_a, exit_s, n_ov=int(round(OVERLAP * pa * SR)), pa=pa, pb=pb, ratio=ratio,
                               overlap=OVERLAP, gain=gain, out_dir=out_dir)
            check = check_mix(res[0]["file"], start_a, start_a + OVERLAP * pa, pa)
            swap_t = start_a + HALF * pa
            for r in res:
                r.update(plan={"outgoingPeriod": pa, "incomingPeriod": pb, "ratio": ratio, "gain": gain,
                               "blendStart": start_a, "incomingShiftSamples": shift, "sampleRate": SR,
                               "outgoingSwapBeat": int(sa), "incomingSwapBeat": int(sb),
                               "outgoingGridPhase": float(A.grid[0]), "incomingGridPhase": float(B.grid[0]),
                               "grooveLagMs": -delta * 1000, "bandOnsetsMs": [o * 1000 for o in g[1]],
                               "outgoingDrops": [int(i) for i in A.drops], "outgoingExits": [int(i) for i in A.exits],
                               "incomingDrops": [int(i) for i in B.drops], "incomingExits": [int(i) for i in B.exits],
                               "outgoingBar": A.bar, "outgoingPhrase": A.phrase,
                               "incomingBar": B.bar, "incomingPhrase": B.phrase})
                r.update(label=label, style=kind, check=check, reading=reading,
                         why=f"swap on the outgoing's {style} at {mmss(A.grid[sa])} and the incoming's {why} "
                             f"at {mmss(B.grid[sb])} of its own track")
            print(f"  {kind}: blend {mmss(start_a)}, swap {mmss(swap_t)} = outgoing {style} {mmss(A.grid[sa])} + "
                  f"incoming {why} {mmss(B.grid[sb])}; groove was {-delta*1000:+.1f} ms late (band onsets {onsets}), "
                  f"moved {delta*1000:+.1f} ms; check on the mix {check['offsetMs']:+.1f} ms {check['verdict']}")
            results += res; done_styles.add(kind)
            break
    if not results:
        print("  no candidate where the bands agree -> phrase cut\n    " + "\n    ".join(why_not[:6]))
        results = align.render(spec, tracks, cache, out_dir, overlap=OVERLAP, cut_only=True)
        for r in results:
            r["style"] = "phrase-cut"; r["why"] = "no point where the groove reading is trustworthy"
    return results


def check_mix(path, start, end, pa):
    """The groove measure on the finished mix: outgoing alone before the blend, incoming alone after."""
    import wave
    with wave.open(path) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").reshape(-1, 2) / 32768
    bands = groove.split(x)
    g = groove.offset(bands, bands, start - GROOVE_BEATS * pa, end, GROOVE_BEATS, pa)
    if g is None:
        return {"offsetMs": float("nan"), "verdict": "window off the mix"}
    return {"offsetMs": g[0] * 1000, "bandOnsetsMs": [o * 1000 for o in g[1]],
            "verdict": "PASS" if abs(g[0]) <= 0.003 else "FAIL"}


def write_guide(results, out_dir):
    lines = ["# Listening guide — DJ-planned blends (bass swap on the drop)", "",
             "Each file is two full tracks. The blend starts 8 bars before the swap point; the "
             "incoming comes in without bass, the basses swap ON the downbeat at the swap point, then "
             "the outgoing highs fade over the last 4 bars. Start listening ~20 s before the blend.", ""]
    for r in results:
        lines += [f"## {r['label']} — {r['style']}", f"`{r['file']}`", "", f"- {r.get('why', '')}",
                  f"- Placed by the groove; check on the mix: {r['check'].get('offsetMs', float('nan')):+.1f} ms "
                  f"{r['check'].get('verdict')}" if r["style"] != "phrase-cut" else "- No overlap: the outgoing fades "
                  "over its last bar and the incoming starts on the phrase downbeat", ""]
        lines += [f"- **{mmss(t)}** — {m}" for m, t in r["marks"]] + [""]
    path = os.path.join(out_dir, "LISTENING-GUIDE.md")
    open(path, "w").write("\n".join(lines))
    return os.path.abspath(path)


def main():
    args = sys.argv[1:]
    cand, out_dir, cache = args[:3]
    os.makedirs(out_dir, exist_ok=True)
    tracks = json.load(open(cand))
    results = []
    for spec in args[3:]:
        results += render(tuple(spec.split(":")), tracks, cache, out_dir)
    json.dump(results, open(os.path.join(out_dir, "summary.json"), "w"), indent=1, default=float)
    print("guide:", write_guide(results, out_dir))


if __name__ == "__main__":
    main()
