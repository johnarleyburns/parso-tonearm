#!/usr/bin/env python3
"""Write the DJ regression suite's fixture audio (spec §53.8, §54.6).

Twelve tracks at exactly 122.000 BPM — six per genre the lane browses — plus a
124.000 BPM pair for the sync lane. Every one is byte-distinct, which the writer
asserts: the library dedupes on content hash, so identical fixtures would import
as a single track and quietly shrink a crate. Generated, never committed — no
binary in the repo, and no third-party audio, Creative Commons included (§54.6).

WHY THESE ARE SYNTHETIC
-----------------------
Real music makes every transition assertion mush. A techno track has broadband
low end on both decks, so "did the bass swap?" has no crisp answer. Each fixture
here is three sine tones, one per EQ band, and **the two deck roles use different
frequencies within the same band**:

    band (EQ crossover)   deck-A set    deck-B set
    low   (< 200 Hz)        55 Hz         87 Hz
    mid   (200 Hz - 2 kHz) 611 Hz       1290 Hz
    high  (> 2 kHz)       5300 Hz       8900 Hz

The frequencies are deliberately NOT in simple integer ratios, so no tone is a
harmonic of another and intermodulation cannot be mistaken for the tone it sits
beside. They sit unambiguously inside the same 200 Hz / 2 kHz crossovers the
mixer's three-band EQ uses (§26A.2), so "the LOW knob killed the low band" and
"the 55 Hz tone disappeared" are the same statement.

That is what makes band energy *attributable to a specific deck*, and it is the
whole reason the gating lane can prove a bass swap happened rather than merely
observing that something changed.

Each tone is amplitude-modulated on the beat so tempo and beat positions are
genuinely detectable, and tracks carry 16-bar phrase structure so the segmenter
produces a real phrase ribbon and "swap on the phrase boundary" has a boundary
to land on.

    python3 make-dj-fixture-media.py /media
"""

import argparse
import array
import hashlib
import json
import math
import os
import sys
import wave

SAMPLE_RATE = 48_000
BEATS_PER_BAR = 4
BARS_PER_PHRASE = 16

# Peak level per track. -12 dBFS leaves headroom so that limiter engagement in
# the Blend lane means something rather than being inevitable.
PEAK = 0.25

TONE_SETS = {
    "a": {"low": 55.0, "mid": 611.0, "high": 5300.0},
    "b": {"low": 87.0, "mid": 1290.0, "high": 8900.0},
}

# Phrase structure without touching the measured bands.
#
# The arrangement used to raise and lower the three tones across an arc. That
# reads well and measures terribly: every assertion in §53.9 is a dB *change* in
# one of those bands, so an arrangement that moves them by 9 dB on a phrase
# boundary plants a ±9 dB error in the middle of the thing being measured — the
# analyzer cannot tell an EQ kill from the arrangement, and neither could a
# human reading the verdict table.
#
# So the three identity tones hold a constant level for the whole track, and the
# phrase boundary is carried by a short marker blip at a frequency **no
# assertion measures**. The segmenter still has boundaries to find and the
# ribbon still has something to label.
MARKER_HZ = 2_200.0
MARKER_SECONDS = 0.06
MARKER_LEVEL = 0.05

# A per-track tone, far below anything measured, that makes every fixture
# byte-distinct without disturbing a single band. The library dedupes on content
# hash, so two identical files import as one track and silently shorten a crate.
SERIAL_BASE_HZ = 3_100.0
SERIAL_STEP_HZ = 53.0
SERIAL_LEVEL = 0.006

# Per-band beat envelope decay (1/seconds): the attack is instantaneous, so the
# beat stays unmistakable to an onset detector, and the tail is long enough that
# each tone stays spectrally *narrow*.
#
# This is a measurement constraint as much as a musical one. A sharply-enveloped
# 55 Hz tone smears across tens of Hz, and the analyzer then cannot tell it from
# deck B's 87 Hz — which caps an observed "kill" at around 16 dB however
# completely the EQ actually killed it. Gentler decays keep the deck identities
# separable, which is the whole premise of the fixture design (§53.8).
DECAY = {"low": 4.0, "mid": 3.0, "high": 4.0}

# Sine-table resolution and the fixed-point fraction under it.
SINE_TABLE = 8192
PHASE_BITS = 16
PHASE_SCALE = 1 << PHASE_BITS


def render_track(bpm: float, tone_set: str, phrases: int, variant: int = 0) -> bytes:
    """One fixture track as 16-bit mono PCM frames.

    `variant` selects the serial tone and shifts the phrase-marker pattern, so
    **no two fixtures are byte-identical** while every track keeps its role's
    tone identity exactly, at a constant level, for its whole length.
    """
    tones = TONE_SETS[tone_set]
    seconds_per_beat = 60.0 / bpm
    samples_per_beat = SAMPLE_RATE * seconds_per_beat
    beats_per_phrase = BEATS_PER_BAR * BARS_PER_PHRASE
    total_beats = beats_per_phrase * phrases
    total_samples = int(round(total_beats * samples_per_beat))
    marker_samples = int(MARKER_SECONDS * SAMPLE_RATE)
    serial_hz = SERIAL_BASE_HZ + SERIAL_STEP_HZ * variant

    # The three identity tones share the level budget evenly, so a track peaks
    # near PEAK rather than clipping.
    per_tone = PEAK / len(tones)

    # A sine table with fixed-point phase accumulators. These files run to hours
    # of audio in total and are regenerated on every run; three `math.sin` calls
    # per sample is most of that time, and a table lookup is exact enough for
    # tones that are only ever measured as band energy.
    table = [math.sin(2.0 * math.pi * i / SINE_TABLE) for i in range(SINE_TABLE)]
    mask = SINE_TABLE * PHASE_SCALE - 1

    def accumulator(hz):
        return 0, int(round(hz / SAMPLE_RATE * SINE_TABLE * PHASE_SCALE))

    voices = []
    for band, freq in tones.items():
        phase, step = accumulator(freq)
        voices.append([phase, step, DECAY[band]])
    marker_phase, marker_step = accumulator(MARKER_HZ)
    serial_phase, serial_step = accumulator(serial_hz)

    # One beat of each envelope, precomputed: the envelope depends only on the
    # position within the beat, which repeats exactly.
    beat_samples = int(round(samples_per_beat))
    envelopes = [[math.exp(-(i / SAMPLE_RATE) * decay) for i in range(beat_samples + 1)]
                 for _, _, decay in voices]

    out = array.array("h", bytes(2 * total_samples))
    for n in range(total_samples):
        beat_index = int(n / samples_per_beat)
        in_beat = n - int(beat_index * samples_per_beat)
        if in_beat > beat_samples:
            in_beat = beat_samples

        value = 0.0
        for index, voice in enumerate(voices):
            value += per_tone * envelopes[index][in_beat] * table[voice[0] >> PHASE_BITS]
            voice[0] = (voice[0] + voice[1]) & mask

        # The phrase marker: a short blip on the phrase's first beat.
        if beat_index % beats_per_phrase == 0 and in_beat < marker_samples:
            fade = 1.0 - in_beat / marker_samples
            value += MARKER_LEVEL * fade * table[marker_phase >> PHASE_BITS]
        marker_phase = (marker_phase + marker_step) & mask

        value += SERIAL_LEVEL * table[serial_phase >> PHASE_BITS]
        serial_phase = (serial_phase + serial_step) & mask

        # Hard safety clamp; the arithmetic above stays under full scale, but a
        # future edit to the levels could not.
        if value > 1.0:
            value = 1.0
        elif value < -1.0:
            value = -1.0
        out[n] = int(value * 32767.0)

    return out.tobytes()


def write_wav(path: str, frames: bytes) -> None:
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(frames)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dest", nargs="?", default="/media",
                        help="output directory (default: /media)")
    parser.add_argument("--phrases", type=int, default=10,
                        help="16-bar phrases per track (default: 10, ~5.2 min at 122 BPM — the "
                             "scripted transitions take minutes of wall clock, and a deck that "
                             "runs out mid-script stops the master clock and the recording)")
    parser.add_argument("--tracks", type=int, default=12,
                        help="122 BPM fixtures to write (default: 12 — six per genre)")
    args = parser.parse_args()

    os.makedirs(args.dest, exist_ok=True)

    # Twelve tracks alternating tone sets — enough for the mock to give each of
    # the lane's two genres its **own** six, which matters because a genre whose
    # tracks are the same files as another genre's imports as one crate: the
    # library dedupes on content hash and the second crate silently mirrors the
    # first. Plus a 124 BPM pair used only by the sync lane.
    #
    # Distinctness comes from the per-track serial tone; the alternating phrase
    # count keeps the crates from being uniform in length as well.
    plan = []
    for index in range(args.tracks):
        role = "a" if index % 2 == 0 else "b"
        phrases = args.phrases + (index % 2)
        plan.append((f"dj-fixture-{index + 1:02d}-{role}-122.wav", 122.0, role, index, phrases))
    plan.append(("dj-fixture-sync-a-124.wav", 124.0, "a", 0, args.phrases))
    plan.append(("dj-fixture-sync-b-124.wav", 124.0, "b", 1, args.phrases))

    manifest = []
    digests = {}
    for name, bpm, role, variant, phrases in plan:
        path = os.path.join(args.dest, name)
        frames = render_track(bpm, role, phrases, variant=variant)
        write_wav(path, frames)
        duration = len(frames) / 2 / SAMPLE_RATE
        # Assert the invariant rather than trusting it: a future edit that made
        # two fixtures identical again would otherwise show up much later, as a
        # crate that is mysteriously short.
        digest = hashlib.sha256(frames).hexdigest()
        if digest in digests:
            raise SystemExit(f"fixture {name} is byte-identical to {digests[digest]} — "
                             "the library would dedupe them into one track")
        digests[digest] = name
        manifest.append({
            "file": name,
            "bpm": bpm,
            "toneRole": role,
            "tones": TONE_SETS[role],
            "durationSeconds": round(duration, 3),
            "barsPerPhrase": BARS_PER_PHRASE,
            "phrases": phrases,
            "sampleRate": SAMPLE_RATE,
            "peak": PEAK,
        })
        print(f"wrote {path}  {bpm:.3f} BPM  role {role}  {duration:.1f}s")

    # The manifest is how the analyzer and the lanes learn which tones belong to
    # which track without hardcoding a second copy of the table above.
    manifest_path = os.path.join(args.dest, "dj-fixture-manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump({"sampleRate": SAMPLE_RATE, "toneSets": TONE_SETS,
                   "tracks": manifest}, handle, indent=2)
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
