#!/usr/bin/env python3
"""Meter-locked blends (2026-10-08): the owner's method with the meter their ears validated.

1. Tempo from the audio; the incoming track is stretched ONCE with keylock to the outgoing tempo
   and stays there (lock.py's stretch).
2. Blend region: an exit phrase on the outgoing track and an entry phrase on the incoming one where
   BOTH beats are readable (meter.stability: phase spread <= 5 ms in every part of the window, in a
   band both tracks share), read over the minute before the blend (outgoing) and after it
   (incoming). The latest readable exit and the earliest readable entry win.
3. Placement: the incoming track is moved so its folded beat phase equals the outgoing one's over
   the blend (meter.fold), never by more than half a beat from the phrase alignment.
4. Keep it there: one tempo and one placement for the rest of the mix. (A per-8-beat nudge was
   tried; it chased the music, not timing, and was removed. See README.)
5. No readable region: no beatmatched overlap. The outgoing track fades over its last bar into
   the phrase downbeat and the incoming one starts there, so two kicks never play together.

Every render is checked with the same meter on the finished mix before it is listed.

Usage: align.py <tracks.json> <out-dir> <cache-dir> <from>:<to>:<label> ...
"""
import json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from blend import SR, decode, fetch, write_wav, rms_db, leading_silence, mmss, smooth  # noqa: E402
import lock
lock.VARIANTS = ("bass-swap",)       # the owner's preferred style (2026-10-08)
from lock import stretched, low_env, audio_period, regular_grid, phrase_phase, place, apply_delay, \
    nudge_curve, mix_variants  # noqa: E402
import meter  # noqa: E402

STRETCHER = os.environ.get("BLEND_STRETCHER", "rubberband")   # or "apple": what iOS can ship


def stretch(path, ratio, cache):
    """The incoming track at `ratio` with keylock. "apple" is AVAudioUnitTimePitch at a rate it can
    represent (n/512) plus AVAudioUnitVarispeed for the rest: the chain iOS would use."""
    if STRETCHER != "apple":
        return stretched(path, ratio, cache)
    import subprocess
    base = os.path.splitext(os.path.basename(path))[0]
    wav = os.path.join(cache, f"{base}.wav")
    if not os.path.exists(wav):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-ar", str(SR), wav], check=True)
    # Within 0.2 % no keylock: varispeed alone moves pitch at most 3.4 cents, and the phase vocoder
    # measurably smeared the kicks at x1.0000 (progressive-house, eurodance).
    mode = "varispeed" if abs(ratio - 1) <= 0.002 else "exact"
    out = os.path.join(cache, f"{base}__apple-{mode}_x{ratio:.6f}.caf")
    if not os.path.exists(out):
        subprocess.run([os.path.join(cache, "apple-stretch"), wav, out, f"{ratio:.6f}", "0", mode],
                       check=True, capture_output=True)
    return out


MAX_SPREAD = 0.008          # s: phase spread across the window's parts for a readable beat
MIN_STEADY = 0.08           # fold magnitude in every part
FLAM_OK = 0.005             # s: what the owner can't hear


def readable(fl, t0, t1, period):
    spread, steady = meter.stability(fl, t0, t1, period)
    return spread <= MAX_SPREAD and steady >= MIN_STEADY, spread, steady


def windows(ga, gb, i, j, pa, overlap, span):
    """Where each track's beat is read: the outgoing over `span` s before the blend, the incoming
    over `span` s after it (its steady body, not the sparse outro or intro inside the overlap).
    Dance tracks are quantised to one tempo, so that phase holds through the blend."""
    return (ga[i] - span, ga[i]), (gb[j] + overlap * pa, gb[j] + overlap * pa + span)


def choose_region(a, b, ga, gb, fa, fb, pa, overlap, silence):
    """(exit_idx, entry_idx, band, span) of the latest exit and earliest entry whose beats are
    readable in one band on both tracks, or Nones."""
    fl_a = {band: meter.flux(a, band) for band in meter.BANDS}
    fl_b = {band: meter.flux(b, band) for band in meter.BANDS}
    exits = [i for i in range(fa, len(ga), 32) if i + overlap < len(ga) and ga[i] > 90][::-1]
    entries = [j for j in range(fb, len(gb), 32) if gb[j] >= silence and gb[j] + overlap * pa + 60 < len(b) / SR][:4]
    for i in exits:
        for j in entries:
            # The kick band only. Other bands read a bassline or snare as the beat: techno placed
            # by its 160-400 Hz band flammed badly (owner, 2026-10-08), as did deep-house, whose
            # kick can't be read. Those pairs get the phrase cut.
            for band in ("kick",):
                for span in (60, 120):
                    wa, wb = windows(ga, gb, i, j, pa, overlap, span)
                    if readable(fl_a[band], *wa, pa)[0] and readable(fl_b[band], *wb, pa)[0]:
                        return i, j, band, span, fl_a, fl_b
    return None, None, None, None, fl_a, fl_b


def render(spec, tracks, cache, out_dir, overlap=64, cut_only=False):
    a_id, b_id, label = spec
    A, B = tracks[a_id], tracks[b_id]
    a_path, b_path = fetch(A, cache, a_id), fetch(B, cache, b_id)
    a = decode(a_path); b_src = decode(b_path)
    pa, pha, _ = audio_period(low_env(a), A["bpm"])
    pb, phb, _ = audio_period(low_env(b_src), B["bpm"])
    ratio = pb / pa
    b_stretched = stretch(b_path, ratio, cache)
    b = decode(b_stretched)
    measured = ratio                                 # exact by construction (Apple output is padded, lengths lie)
    ga = regular_grid(pa, pha, len(a) / SR)
    gb = regular_grid(pb / measured, phb / measured, len(b) / SR)
    gain = 10 ** ((rms_db(a) - rms_db(b)) / 20)
    fa, _ = phrase_phase(a, ga)
    fb, _ = phrase_phase(b, gb)
    silence = leading_silence(b)
    exit_idx, entry_idx, band, span, fl_a, fl_b = (None,) * 6 if cut_only else \
        choose_region(a, b, ga, gb, fa, fb, pa, overlap, silence)
    head = (f"\n{label}: {A['title']} -> {B['title']}  {60/pa:.3f} -> {60/pb:.3f} BPM, incoming x{ratio:.5f} keylocked")

    if exit_idx is None:
        # Fallback: no beat both tracks can be locked on. Cut on the phrase downbeat.
        exit_idx = max(i for i in range(fa, len(ga), 32) if i + overlap < len(ga))
        entry_idx = next(i for i in range(fb, len(gb), 32) if gb[i] >= silence)
        exit_t, entry_t = ga[exit_idx], gb[entry_idx]
        exit_s = int(round(exit_t * SR)); shift = exit_s - int(round(entry_t * SR))
        n = len(b) + shift
        bar = int(round(4 * pa * SR))
        mix = np.zeros((n, 2), np.float32)
        mix[:exit_s - bar] = a[:exit_s - bar]
        fade = np.cos(np.linspace(0, np.pi / 2, bar))[:, None]
        mix[exit_s - bar:exit_s] = a[exit_s - bar:exit_s] * fade
        # The incoming starts at its entry downbeat, nothing of it before (its intro under the
        # outgoing's last bar would clash), with a 3 ms fade-in ending on the downbeat so the
        # start can't click.
        inc = place(b, shift, n)
        ramp = int(0.003 * SR)
        inc[:exit_s - ramp] = 0
        inc[exit_s - ramp:exit_s] *= np.linspace(0, 1, ramp)[:, None]
        mix += inc * gain
        name = f"{label}__fallback-phrase-cut.wav"
        path = os.path.abspath(os.path.join(out_dir, name))
        write_wav(path, mix)
        print(head + f"\n  no readable beat region on both tracks -> fallback phrase cut at {mmss(exit_t)}, "
              f"")
        cut = [{"file": path, "label": label, "placement": "fallback", "variant": "phrase-cut", "overlapBeats": 0,
                 "marks": [("outgoing fades over its last bar", exit_t - 4 * pa),
                           ("incoming starts on the phrase downbeat", exit_t)],
                 "lengthSec": n / SR, "check": {"verdict": "fallback: no overlapping kicks"},
                 "outgoing": f"{A['title']} — {A['artist']}", "incoming": f"{B['title']} — {B['artist']}"}]
        return cut

    exit_t, entry_t = ga[exit_idx], gb[entry_idx]
    blend_len = overlap * pa
    # 3. Placement by the meter, read where each track's beat is steady (see windows()).
    wa, wb = windows(ga, gb, exit_idx, entry_idx, pa, overlap, span)
    phi_a, _ = meter.fold(fl_a[band], *wa, pa)
    phi_b, _ = meter.fold(fl_b[band], *wb, pa)
    shift_t = exit_t - entry_t
    delta = meter.wrap(phi_a - (phi_b + shift_t), pa)
    shift_t += delta
    shift = int(round(shift_t * SR))
    exit_s = int(round(exit_t * SR))
    n = len(b) + shift
    # 4. Kept there by construction: one tempo for the rest of the mix and one placement. A per-8-beat
    # nudge was tried and removed: local readings across two different tracks swing +-10 ms with the
    # music (fills, drops, sparse intros), so following them added flam instead of removing it.
    delay = np.zeros(n)
    inc = place(b, shift, n)
    print(head + f"\n  blend {mmss(exit_t)} (out beat {exit_idx}, in beat {entry_idx}), band '{band}', "
          f"read over {span} s, moved {delta*1000:+.1f} ms from the phrase grid")

    results = mix_variants(label, "locked", A, B, a, a_path, b_stretched, inc, shift, n, delay,
                           exit_t, exit_s, n_ov=int(round(overlap * pa * SR)), pa=pa, pb=pb, ratio=ratio,
                           overlap=overlap, gain=gain, out_dir=out_dir)
    # Check: the outgoing before the blend against the incoming after it, on the finished mix.
    check = verify(results[0]["file"], exit_t, exit_t + blend_len, pa, band, span)
    print(f"  check on the mix: incoming {check['offsetMs']:+.1f} ms vs outgoing -> {check['verdict']}")
    for r in results:
        r["check"] = check
        r["band"] = band
    return results


def verify(path, start, end, pa, band, span=60):
    import wave
    with wave.open(path) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").reshape(-1, 2) / 32768
    fl = meter.flux(x, band)
    po, so = meter.fold(fl, start - span, start, pa)
    pi, si = meter.fold(fl, end, end + span, pa)
    d = meter.wrap(pi - po, pa)
    ok = min(so, si) >= MIN_STEADY
    verdict = ("PASS" if abs(d) <= FLAM_OK else "FAIL") if ok else "unreadable on the mix"
    return {"offsetMs": d * 1000, "steadiness": [so, si], "verdict": verdict}


def write_guide(results, out_dir):
    lines = ["# Listening guide — meter-locked blends", "",
             "Every file is two full tracks: the outgoing track from its start, the blend, then the "
             "incoming track to its end. The incoming track is tempo-matched once with keylock "
             f"({'Apple AVAudioUnitTimePitch + Varispeed, as iOS would' if STRETCHER == 'apple' else 'Rubber Band'}) and "
             "stays there; its beat is placed with the meter your A/B verdicts validated, and kept "
             "there through the blend. Times are elapsed time; start ~20 s before the blend.", ""]
    for label in dict.fromkeys(r["label"] for r in results):
        g = [r for r in results if r["label"] == label]
        c = g[0]["check"]
        lines += [f"## {label}", "", f"- Outgoing: {g[0]['outgoing']}", f"- Incoming: {g[0]['incoming']}",
                  f"- Meter check: {c.get('offsetMs', float('nan')):+.1f} ms → {c['verdict']}" if "offsetMs" in c
                  else f"- {c['verdict']}", ""]
        for r in g:
            what = {"equal-power": "Equal-power fade. Listen for a double kick (flam) or gallop, "
                                   "especially from 'both tracks at equal level' to the midpoint.",
                    "bass-swap": "DJ style: the incoming comes in without bass; at the midpoint the basses "
                                 "swap on the phrase downbeat. Listen for one clean drop.",
                    "phrase-cut": "Fallback: these two tracks have no beat both can be locked on, so "
                                  "there is no overlap. Listen for a clean phrase change, no clash."}[r["variant"]]
            lines += [f"### {r['variant']}", f"`{r['file']}`", "", what, ""]
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
