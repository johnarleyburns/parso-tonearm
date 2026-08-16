#!/usr/bin/env python3
"""Verify a recorded Platterhead mix against its journal (spec §53.8-53.10).

    verify-mix.py mix.m4a mix-journal.json [--fixture-manifest dj-fixture-manifest.json]

WHY THIS EXISTS
---------------
`XCUITest` cannot hear. A lane that asserts "the deck row says Playing" is the
D-10 false green exactly (§53.5): a library that adds cleanly and plays nothing
would have passed it for the defect's entire life. So the DJ lanes assert against
**the recording the app itself produced** — decoded here, on the host, by code
that is not Platterhead.

The oracle is independent of the app's opinion of itself, it is the actual M5
deliverable rather than a proxy for it, and it exercises the whole chain at once:
gesture -> command ring -> engine -> mixer -> record tap -> encoder -> export.

TWO ARTIFACTS, CROSS-CHECKED (§53.9)
------------------------------------
The journal says where each transition *claims* to be; this script checks the
acoustic signature *is* there. The journal alone proves only that the app
believes it acted; the audio alone proves only that something happened. Together
they prove the app did what it says it did, where it says it did.

The journal also carries the engine configuration in force (limiter ceiling,
master BPM, echo division, sample rate), so the recording is self-describing.
That is the mechanism behind "thresholds come from one definition": this script
runs on the host and cannot import `Limiter.ceiling`, so the app writes the value
it actually used and we read it, rather than hardcoding a copy that a later
retune would silently invalidate.

TOLERANCE (§53.10)
------------------
Every assertion here is **relative** (dB changes and ratios between tones, never
absolute levels) and **bar-tolerant** (whole bars around the journal mark, never
a sample offset). Sample precision is layer 1's job, against the deterministic
offline render. This layer runs in real time on a simulator that can underrun;
demanding precision here produces a suite that is red for reasons nobody can fix,
and §53.4 exists because such a suite stops being read.
"""

import argparse
import array
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave

# Analysis window. 4096 at 48 kHz is ~85 ms — short enough to resolve a fader cut
# inside one beat, long enough to resolve 55 Hz from 87 Hz.
WINDOW = 4096
HOP = WINDOW // 2

# Only windows near a journal mark are analysed (see the span constants below),
# which is what keeps a pure-stdlib Goertzel viable on a 20-minute file.
#
# WHERE THE WINDOWS GO, AND WHY IT IS NOT A THRESHOLD QUESTION
# -----------------------------------------------------------
# A journal mark is where the app *recognised* the gesture — and for the two
# multi-step transitions that is where the gesture **began**, not where it
# ended. A bass swap is one deck's low killed and the other's restored: the app
# marks the kill, and the hand still has to reach the other deck's knob. A
# filter transition is marked as the knob leaves the bypass band, and the sweep
# runs on for a couple of bars after that.
#
# So a window placed one bar past the mark measures the transition **mid-flight**
# and reports a real, correct transition as a half-failure. That is a
# measurement bug, not a threshold that needs loosening: the physical claim
# ("the low ended up on the other deck", "the low is gone and the top is still
# there") is unchanged — it is asserted against the *settled* state instead of
# against the middle of the movement.
#
# The lane guarantees the spacing these spans assume: every transition is
# scheduled relative to the bar the previous gesture *finished* on, with at
# least eight clear bars either side of a mark (`DJMixRegressionUITests`).
SETTLED_PRE_BARS = (-4, -2)      # settled material before the gesture starts
SETTLED_POST_BARS = (4, 6)       # a mark at a gesture's start: let it land first
COMPLETED_POST_BARS = (1, 3)     # a mark at a gesture's completion: one guard bar
SWEEP_BARS = 3                   # how long a hand takes to walk a filter across

# How far past an Echo Out's cut the tail is measured. The script holds the
# channel down for longer than this, so the window never runs into the deck
# coming back (§53.9 row 3).
TAIL_BARS = 4

SILENCE_FLOOR_DB = -90.0


# ── decoding ────────────────────────────────────────────────────────────────


def decode_to_wav(path: str, workdir: str) -> str:
    """Decode any input to 16-bit mono WAV via ffmpeg. WAV input passes through."""
    if path.lower().endswith(".wav"):
        return path
    if shutil.which("ffmpeg") is None:
        raise SkipCondition("ffmpeg not found — install it to decode the export "
                            "(`brew install ffmpeg`)")
    out = os.path.join(workdir, "decoded.wav")
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", path, "-ac", "1", "-c:a", "pcm_s16le", out],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise VerificationError(f"the export did not decode: {result.stderr.strip()}")
    return out


def read_samples(path: str):
    with wave.open(path, "rb") as handle:
        if handle.getsampwidth() != 2:
            raise VerificationError("expected 16-bit PCM after decode")
        rate = handle.getframerate()
        channels = handle.getnchannels()
        raw = handle.readframes(handle.getnframes())
    data = array.array("h")
    data.frombytes(raw)
    if channels > 1:
        data = array.array("h", data[::channels])
    return data, rate


# ── measurement ─────────────────────────────────────────────────────────────


def goertzel_energy(samples, start: int, freq: float, rate: int) -> float:
    """Energy at `freq` over one window starting at `start`, Hann-weighted."""
    end = min(start + WINDOW, len(samples))
    if end - start < WINDOW // 2:
        return 0.0
    omega = 2.0 * math.pi * freq / rate
    coeff = 2.0 * math.cos(omega)
    s1 = s2 = 0.0
    count = end - start
    for i in range(count):
        # Hann window: suppresses the skirts of neighbouring tones so 55 Hz and
        # 87 Hz stay separable.
        w = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / (count - 1)) if count > 1 else 1.0
        sample = (samples[start + i] / 32768.0) * w
        s0 = sample + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return max(power, 0.0) / (count * count)


def db(value: float) -> float:
    if value <= 0.0:
        return SILENCE_FLOOR_DB
    return max(SILENCE_FLOOR_DB, 10.0 * math.log10(value))


def bar_samples(rate: int, bpm: float) -> float:
    return 4.0 * 60.0 / bpm * rate


def span_starts(centre_sample: int, rate: int, bpm: float, span, total: int):
    """Window starts covering `span` (bar offsets) around a journal mark."""
    bar = bar_samples(rate, bpm)
    lo = max(0, int(centre_sample + span[0] * bar))
    hi = min(total - WINDOW, int(centre_sample + span[1] * bar))
    starts = list(range(lo, hi, HOP))
    if not starts:
        raise VerificationError(
            f"not enough recording {span[0]:+d}..{span[1]:+d} bars around the mark to "
            "judge it — the transition is too close to an edge of the recording")
    return starts


def band_level(samples, rate: int, bpm: float, centre: int, freq: float, span) -> float:
    """Mean dB at `freq` over `span`.

    Averaged over every window in the span rather than sampled at its edges: the
    fixtures are amplitude-modulated on their own 122 BPM beat while these spans
    are measured on the *master* clock's bar, so a single window lands at an
    arbitrary point in the beat envelope and reads several dB off. A span of a
    bar or more averages the envelope out, and the number becomes the band's
    level rather than the beat's phase.
    """
    starts = span_starts(centre, rate, bpm, span, len(samples))
    return sum(db(goertzel_energy(samples, s, freq, rate)) for s in starts) / len(starts)


def spectral_centroid(samples, start: int, rate: int, freqs) -> float:
    total = 0.0
    weighted = 0.0
    for f in freqs:
        e = goertzel_energy(samples, start, f, rate)
        total += e
        weighted += e * f
    return weighted / total if total > 0 else 0.0


def mean_centroid(samples, rate: int, bpm: float, centre: int, freqs, span) -> float:
    """The tone set's centroid over `span`, averaged the same way as a band."""
    starts = span_starts(centre, rate, bpm, span, len(samples))
    return sum(spectral_centroid(samples, s, rate, freqs) for s in starts) / len(starts)


# ── signature checks (§53.9) ────────────────────────────────────────────────


class VerificationError(Exception):
    """An assertion about Platterhead's own behaviour failed."""


class SkipCondition(Exception):
    """A prerequisite is absent. Never a product defect (§53.4)."""


def check_bass_swap(samples, rate, bpm, event, tones):
    """The low end changes hands while the mids play through (§53.9 row 1).

    The mark is the outgoing deck's low being killed — the *first* half. The
    incoming deck's low comes back a beat or two later, when the hand gets
    there, so the swap is judged once both halves have landed.
    """
    out_low = tones[event["outgoing"]]["low"]
    in_low = tones[event["incoming"]]["low"]
    out_mid = tones[event["outgoing"]]["mid"]
    in_mid = tones[event["incoming"]]["mid"]
    at = event["atSample"]

    def level(freq, span):
        return band_level(samples, rate, bpm, at, freq, span)

    pre_out, post_out = level(out_low, SETTLED_PRE_BARS), level(out_low, SETTLED_POST_BARS)
    pre_in, post_in = level(in_low, SETTLED_PRE_BARS), level(in_low, SETTLED_POST_BARS)
    pre_om, post_om = level(out_mid, SETTLED_PRE_BARS), level(out_mid, SETTLED_POST_BARS)
    pre_im, post_im = level(in_mid, SETTLED_PRE_BARS), level(in_mid, SETTLED_POST_BARS)

    notes = []
    ok = True
    if pre_out - post_out < 24.0:
        ok = False
        notes.append(f"outgoing low fell only {pre_out - post_out:.1f} dB (need 24)")
    if post_in - pre_in < 24.0:
        ok = False
        notes.append(f"incoming low rose only {post_in - pre_in:.1f} dB (need 24)")
    # The mids persisting is what distinguishes a bass swap from a cut. Without
    # this half, lanes 1 and 4 would pass on the same evidence.
    if abs(post_om - pre_om) > 3.0:
        ok = False
        notes.append(f"outgoing mid moved {post_om - pre_om:+.1f} dB — that is a cut, not a swap")
    if abs(post_im - pre_im) > 3.0:
        ok = False
        notes.append(f"incoming mid moved {post_im - pre_im:+.1f} dB — that is a cut, not a swap")
    return ok, "; ".join(notes) or (
        f"low {pre_out - post_out:.0f} dB out / {post_in - pre_in:.0f} dB in, mids held")


def check_filter(samples, rate, bpm, event, tones):
    band = tones[event["outgoing"]]
    at = event["atSample"]
    freqs = [band["low"], band["mid"], band["high"]]

    # The centroid's *shape* is judged across the sweep — the movement itself,
    # which runs forward from the mark, because the app marks a filter
    # transition where the knob leaves the bypass band and that is where the
    # hand started moving. A sweep performed the way a DJ performs one takes a
    # couple of bars, so the shape is read over `SWEEP_BARS`; over a longer span
    # most windows sit in the flat material afterwards and the test would be
    # asking the material to keep climbing after the DJ let go.
    sweep = span_starts(at, rate, bpm, (0, SWEEP_BARS), len(samples))
    centroids = [spectral_centroid(samples, s, rate, freqs) for s in sweep]

    # "Rises" is judged over **four means spanning the sweep**, per §53.9 — not
    # over every 40 ms hop. Each tone carries a per-beat envelope with its own
    # decay, so the frame-to-frame centroid wobbles by hundreds of hertz around
    # its trend; asking that wobble to be monotonic is asking the beat not to
    # happen. Four means over the sweep is the trend, which is what
    # distinguishes a sweep from a jump or a fade.
    quarters = []
    if centroids:
        size = max(1, len(centroids) // 4)
        for index in range(4):
            chunk = centroids[index * size:(index + 1) * size] or centroids[-1:]
            quarters.append(sum(chunk) / len(chunk))
    # **Three of the four** (§53.9 row 2, plan §6 row 2) — one quarter is allowed
    # not to rise. The span has to be long enough for a slow sweep, which means
    # it usually outlasts a quick one: the hand arrives, the filter holds, and
    # the last quarter measures the hold, where the envelope moves the centroid
    # by tens of hertz either way. Demanding all four makes the check a coin toss
    # on where the hand stopped, and the *magnitude* claim below is what says the
    # filter actually opened up the top.
    steps = list(zip(quarters, quarters[1:]))
    rising = sum(1 for a, b in steps if b >= a - 50.0)
    required = max(1, len(steps) - 1)

    # And it must actually end higher — measured **settled to settled**, not
    # from the first to the last quarter of the sweep. The endpoints of a
    # movement are the worst place to measure where it arrived: the last
    # quarter still has the hand in it if the sweep ran a moment long, and the
    # claim being made is about the filter's effect, not about the hand's
    # speed. Removing the low from a 55/611/5300 Hz identity moves the centroid
    # by several hundred hertz.
    pre_centroid = mean_centroid(samples, rate, bpm, at, freqs, SETTLED_PRE_BARS)
    post_centroid = mean_centroid(samples, rate, bpm, at, freqs, SETTLED_POST_BARS)

    low_pre = band_level(samples, rate, bpm, at, band["low"], SETTLED_PRE_BARS)
    low_post = band_level(samples, rate, bpm, at, band["low"], SETTLED_POST_BARS)
    high_pre = band_level(samples, rate, bpm, at, band["high"], SETTLED_PRE_BARS)
    high_post = band_level(samples, rate, bpm, at, band["high"], SETTLED_POST_BARS)

    notes = []
    ok = True
    if rising < required:
        ok = False
        notes.append(f"centroid climbed in only {rising} of {len(steps)} quarter-to-quarter "
                     f"steps across the sweep (need {required})")
    if post_centroid - pre_centroid < 300.0:
        ok = False
        notes.append(f"centroid rose only {post_centroid - pre_centroid:.0f} Hz once the "
                     "sweep settled (need 300) — that is not a filter opening up the top")
    if low_pre - low_post < 18.0:
        ok = False
        notes.append(f"low fell only {low_pre - low_post:.1f} dB (need 18)")
    if abs(high_post - high_pre) > 6.0:
        ok = False
        notes.append(f"high moved {high_post - high_pre:+.1f} dB — that is a fade, not a high-pass")
    return ok, "; ".join(notes) or (f"centroid +{post_centroid - pre_centroid:.0f} Hz once "
                                    f"settled, low -{low_pre - low_post:.0f} dB, high held")


def check_filter_bypass(samples, rate, bpm, event, tones, pre_sweep_low):
    """Centre is bypass (§35.3): low returns to its **pre-sweep** level.

    The bypass mark sits after the sweep, so a naive before/after around it
    would compare the closed (filtered) level to the reopened level — a filter
    that worked would look like a failure. The caller therefore passes the low
    level measured before the preceding `transition.filter` sweep, and this
    checks the reopened low has come back to within 3 dB of it.

    Unlike the sweep, this mark fires at the movement's **completion** — the
    knob has arrived in the bypass band — so one guard bar is enough.
    """
    band = tones[event["outgoing"]]
    at = event["atSample"]
    if pre_sweep_low is None:
        raise VerificationError("no preceding filter sweep to compare centre-return against")
    post = band_level(samples, rate, bpm, at, band["low"], COMPLETED_POST_BARS)
    ok = abs(post - pre_sweep_low) <= 3.0
    return ok, (f"low returned within {abs(post - pre_sweep_low):.1f} dB of pre-sweep" if ok
                else f"low is {post - pre_sweep_low:+.1f} dB off its pre-sweep level — centre is not bypass")


def check_echo_out(samples, rate, bpm, event, tones):
    band = tones[event["outgoing"]]
    at = event["atSample"]           # the moment the fader reached zero
    seconds_per_beat = 60.0 / bpm
    division = event.get("echoDivision", 0.5)
    interval = seconds_per_beat * division

    # Look at the tail only: from the cut forward, and only as far as the cut is
    # held. Running past the point where the channel comes back measures the
    # deck, not its echo — the tail looks like it never decayed.
    span = int(TAIL_BARS * 4 * seconds_per_beat * rate)
    # A finer hop than the general one: the repeat interval is measured from the
    # spacing of peaks in this curve, so the hop is the measurement's resolution.
    # At the general HOP a 500 ms interval can only be resolved to about ±9%,
    # which is looser than the ±5% the interval is asserted to — the check would
    # be failing on its own arithmetic.
    tail_hop = WINDOW // 8
    starts = list(range(at, min(at + span, len(samples)), tail_hop))
    if len(starts) < 8:
        raise VerificationError("recording ends too soon after the cut to observe a tail")

    # The tail is measured on the outgoing deck's **mid** tone alone. It is the
    # best-isolated of its three identities — the two decks' lows sit 32 Hz
    # apart, closer than this window can separate at tail levels, so a low-band
    # curve measures the other deck's bleed and reports it as an echo that never
    # decays.
    curve = [db(goertzel_energy(samples, s, band["mid"], rate)) for s in starts]

    notes = []
    ok = True
    # A pre-fader echo dies with the fader and leaves no tail at all. This lane is
    # what proves the echo is post-fader (§35A).
    if max(curve[:8]) < SILENCE_FLOOR_DB + 20.0:
        return False, ("no tail after the fader reached zero — the echo is pre-fader, "
                       "or is not running")

    # Repeats land one echo interval apart; anything closer than two-thirds of
    # that is ripple, not a repeat.
    peaks = find_peaks(curve, min_separation=max(1, int(0.66 * interval * rate / tail_hop)))

    # Judge the decaying run, and stop where it ends. An echo tail decays until
    # it disappears under the deck that is still playing — which is the whole
    # point of an Echo Out — and the "peaks" below that are the other deck's
    # material. Asking them to keep decreasing asks the wrong signal to behave.
    run = peaks[:1]
    for peak in peaks[1:]:
        if curve[peak] > curve[run[-1]] + 1.0:
            break
        run.append(peak)

    notes_len = len(run)
    if notes_len < 3:
        ok = False
        notes.append(f"only {notes_len} decaying repeats found (need 3) — the tail is not "
                     "a beat-synced echo dying away")
    else:
        spacing = [(starts[b] - starts[a]) / rate for a, b in zip(run, run[1:])]
        mean = sum(spacing) / len(spacing)
        if abs(mean - interval) / interval > 0.05:
            ok = False
            notes.append(f"repeats every {mean * 1000:.0f} ms, expected {interval * 1000:.0f} ms")

    # "Decays to silence" is measured **relative to the tail's own first repeat**,
    # not against an absolute floor. The other deck is still playing, so the
    # master never goes quiet, and the honest question is whether this deck's
    # echo died away rather than whether the room did.
    decay = (curve[run[0]] - curve[run[-1]]) if len(run) > 1 else 0.0
    if decay < 20.0:
        ok = False
        notes.append(f"tail fell only {decay:.0f} dB across its repeats (need 20)")
    return ok, "; ".join(notes) or (f"{len(run)} repeats at the beat-synced interval, "
                                    f"decaying {decay:.0f} dB")


def find_peaks(curve, min_separation: int = 1, prominence: float = 3.0):
    """Local maxima that are actually repeats.

    Every ripple in a decaying tail is a local maximum, and counting them makes
    the measured repeat interval the hop size rather than the echo's. A repeat
    has to stand `prominence` dB above the dip that precedes it and sit at least
    `min_separation` windows from the last one kept.
    """
    raw = [i for i in range(1, len(curve) - 1)
           if curve[i] >= curve[i - 1] and curve[i] > curve[i + 1]]
    kept: list = []
    for i in raw:
        if not kept:
            kept.append(i)
            continue
        if i - kept[-1] < min_separation:
            if curve[i] > curve[kept[-1]]:
                kept[-1] = i
            continue
        valley = min(curve[kept[-1]:i + 1])
        if curve[i] - valley >= prominence:
            kept.append(i)
    return kept


def check_fader_cut(samples, rate, bpm, event, tones):
    band = tones[event["outgoing"]]
    at = event["atSample"]
    seconds_per_beat = 60.0 / bpm
    beat = int(seconds_per_beat * rate)

    pre_start = max(0, at - beat)
    post_start = min(len(samples) - WINDOW, at + beat)
    freqs = [band["low"], band["mid"], band["high"]]
    pre = db(sum(goertzel_energy(samples, pre_start, f, rate) for f in freqs))
    post = db(sum(goertzel_energy(samples, post_start, f, rate) for f in freqs))

    notes = []
    ok = True
    if pre - post < 30.0:
        ok = False
        notes.append(f"outgoing fell only {pre - post:.1f} dB inside one beat (need 30)")

    # No zipper: a click is broadband, so it shows up as unusually flat spectrum
    # right at the cut compared with the material either side.
    flat_at = spectral_flatness(samples, at, rate)
    flat_ref = max(spectral_flatness(samples, pre_start, rate), 1e-9)
    if flat_at > flat_ref * 8.0:
        ok = False
        notes.append(f"broadband transient at the cut (flatness {flat_at:.3f} vs {flat_ref:.3f}) — zipper")
    return ok, "; ".join(notes) or f"-{pre - post:.0f} dB inside one beat, no broadband transient"


def spectral_flatness(samples, start: int, rate: int) -> float:
    """Geometric/arithmetic mean ratio over a coarse probe set."""
    probes = [40, 80, 160, 320, 640, 1280, 2560, 5120, 10240]
    energies = [max(goertzel_energy(samples, start, f, rate), 1e-15) for f in probes]
    geo = math.exp(sum(math.log(e) for e in energies) / len(energies))
    arith = sum(energies) / len(energies)
    return geo / arith if arith > 0 else 0.0


def check_blend(samples, rate, bpm, event, tones, ceiling):
    a = tones[event["outgoing"]]
    b = tones[event["incoming"]]
    at = event["atSample"]
    seconds_per_bar = 4.0 * 60.0 / bpm
    span = int(8 * seconds_per_bar * rate)
    starts = list(range(at, min(at + span, len(samples)), HOP))
    if len(starts) < 8:
        raise VerificationError("recording ends too soon after the blend began")

    both = 0
    for s in starts:
        a_present = db(goertzel_energy(samples, s, a["mid"], rate)) > SILENCE_FLOOR_DB + 20.0
        b_present = db(goertzel_energy(samples, s, b["mid"], rate)) > SILENCE_FLOOR_DB + 20.0
        if a_present and b_present:
            both += 1

    notes = []
    ok = True
    if both / len(starts) < 0.8:
        ok = False
        notes.append(f"both decks audible in only {both / len(starts):.0%} of the blend (need 80%)")

    peak = max(abs(min(samples[at:at + span])), abs(max(samples[at:at + span]))) / 32768.0
    if peak > ceiling + 0.01:
        ok = False
        notes.append(f"peak {peak:.3f} exceeded the limiter ceiling {ceiling:.3f}")
    return ok, "; ".join(notes) or f"both decks present {both / len(starts):.0%} of 8 bars, peak {peak:.3f}"


# ── driver ──────────────────────────────────────────────────────────────────

CHECKS = {
    "transition.bassSwap": ("Bass Swap", check_bass_swap),
    "transition.filter": ("Filter Transition", check_filter),
    "transition.filterBypass": ("Filter — centre is bypass", check_filter_bypass),
    "transition.echoOut": ("Echo Out", check_echo_out),
    "transition.faderCut": ("Fader Cut", check_fader_cut),
    "transition.blend": ("Blend / Mix", check_blend),
}

REQUIRED = ["transition.bassSwap", "transition.filter", "transition.echoOut",
            "transition.faderCut", "transition.blend"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording")
    parser.add_argument("journal")
    parser.add_argument("--fixture-manifest", default=None,
                        help="dj-fixture-manifest.json; falls back to the journal's tone sets")
    args = parser.parse_args()

    try:
        with open(args.journal, encoding="utf-8") as handle:
            journal = json.load(handle)
    except FileNotFoundError:
        print(f"SKIP: no journal at {args.journal} — the app did not export one "
              f"(is it running under -uiRegression?)", file=sys.stderr)
        return 0

    engine = journal.get("engine", {})
    bpm = engine.get("masterBPM")
    ceiling = engine.get("limiterCeiling")
    if bpm is None or ceiling is None:
        print("FAIL: the journal carries no engine config — the recording must be "
              "self-describing (§53.9); the analyzer will not hardcode a ceiling.",
              file=sys.stderr)
        return 1

    tones = journal.get("decks")
    if not tones and args.fixture_manifest:
        with open(args.fixture_manifest, encoding="utf-8") as handle:
            tones = json.load(handle)["toneSets"]
    # No tone sets is the **live lane**, not a broken run: real music has no
    # tone identity to measure and that lane performs no scripted transitions
    # (§8.2, §53.12). The signature table is skipped — but the file is still
    # decoded and held against the journal's own length below, which is exactly
    # what §8.2 asks of the live lane: it browses, plays, records, and the
    # export decodes.
    signatures_apply = bool(tones)

    workdir = tempfile.mkdtemp(prefix="verify-mix-")
    try:
        wav = decode_to_wav(args.recording, workdir)
        samples, rate = read_samples(wav)
    except SkipCondition as exc:
        print(f"SKIP: {exc}", file=sys.stderr)
        return 0
    except VerificationError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    duration = len(samples) / rate
    print(f"recording: {duration:.1f}s @ {rate} Hz · master {bpm:.3f} BPM · ceiling {ceiling:.3f}")

    # **What the app believes it wrote, against what is on disk.** An encoder
    # that lost its tail, or a tap that dropped blocks under a slow drain,
    # otherwise surfaces much later as a transition that is mysteriously not
    # where the journal says it is — and gets diagnosed as a DSP problem.
    length_ok = True
    recorded = journal.get("recording")
    if recorded:
        claimed = recorded.get("durationSeconds", 0.0)
        bar_seconds = 4.0 * 60.0 / bpm
        drift = abs(duration - claimed)
        if drift > bar_seconds:
            length_ok = False
            print(f"  FAIL  the export is {duration:.1f}s but the app recorded {claimed:.1f}s "
                  f"— {drift:.1f}s missing, more than the one bar of tolerance")
        else:
            print(f"  length: {duration:.1f}s, within {drift:.2f}s of the {claimed:.1f}s "
                  "the app recorded")
        # The §53.10 dropout budget, stated rather than implied: the tap drops
        # rather than stalling the render, so a busy host costs the recording a
        # little audio and never the performance. Report it always; fail only
        # past a bar's worth, and as the host condition it is.
        dropped = recorded.get("droppedFrames", 0)
        if dropped:
            lost = dropped / rate
            print(f"  dropped: {dropped} frames ({lost * 1000:.0f} ms) — the record tap's ring "
                  "filled faster than the encoder drained it")
            if lost > bar_seconds:
                length_ok = False
                print(f"  FAIL  {lost:.1f}s of the master bus never reached the file, over the "
                      "one-bar budget — a host condition, not a Platterhead defect, but the "
                      "recording is not trustworthy evidence")
    print()

    if not signatures_apply:
        print("the live lane: no tone identities to measure, so the §53.9 signatures are "
              "not asserted here (§53.12). The export decoded and its length matches the "
              "journal — which is what this lane is for.")
        return 0 if length_ok else 1

    events = journal.get("events", [])
    results = []
    seen = set()
    # For `transition.filterBypass` the reopened low is compared against the
    # pre-sweep level: remember the low level before each filter sweep, per
    # outgoing deck, as the events are walked in journal order.
    pre_sweep_low: dict = {}
    for event in events:
        kind = event.get("kind")
        if kind not in CHECKS:
            continue
        seen.add(kind)
        label, check = CHECKS[kind]
        try:
            if kind == "transition.blend":
                ok, note = check(samples, rate, bpm, event, tones, ceiling)
            elif kind == "transition.filter":
                ok, note = check(samples, rate, bpm, event, tones)
                # The same settled pre-sweep level the sweep itself was judged
                # against, so "centre is bypass" and "the sweep took the low
                # out" are two statements about one number.
                pre_sweep_low[event["outgoing"]] = band_level(
                    samples, rate, bpm, event["atSample"],
                    tones[event["outgoing"]]["low"], SETTLED_PRE_BARS)
            elif kind == "transition.filterBypass":
                ok, note = check(samples, rate, bpm, event, tones,
                                 pre_sweep_low.get(event["outgoing"]))
            else:
                ok, note = check(samples, rate, bpm, event, tones)
        except VerificationError as exc:
            ok, note = False, str(exc)
        results.append((label, event["atSample"] / rate, ok, note))

    missing = [k for k in REQUIRED if k not in seen]
    width = max([len(r[0]) for r in results] + [len(CHECKS[k][0]) for k in missing] + [20])
    for label, at, ok, note in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {label:<{width}}  @{at:7.1f}s  {note}")

    for kind in missing:
        print(f"  FAIL  {CHECKS[kind][0]:<{width}}  {'':8}  not present in the journal — "
              f"the transition was never performed")

    failed = [r for r in results if not r[2]]
    print()
    if failed or missing:
        print(f"{len(failed) + len(missing)} of {len(REQUIRED)} required transitions did not verify")
        return 1
    if not length_ok:
        print("every transition verified, but the recording itself is short of what the app "
              "says it wrote — see above")
        return 1
    print(f"all {len(REQUIRED)} required transitions verified against the journal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
