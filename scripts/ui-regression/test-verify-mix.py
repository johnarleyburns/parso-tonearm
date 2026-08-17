#!/usr/bin/env python3
"""Tests for the mix analyzer's signature checks — `python3 test-verify-mix.py`.

WHY THESE EXIST. `verify-mix.py` is the DJ lanes' only real assertion: XCUITest
cannot hear, so what the app recorded is the evidence and this analyzer is the
oracle. It had no tests of its own, and on 2026-08-16 that cost a release gate —
`check_fader_cut`'s zipper rule fired on a clean recording and the failure was
read as a product defect for a day. It was a **segment-join detector**: 7 of 739
probe points on the beat grid tripped it, every one within 8 ms of a 30-second
encoder-segment boundary (§37.2).

The signals here are synthetic on purpose. A test that needs the kept recording
is a test that cannot run on a clean checkout — the recording is gitignored
build output — so these render the fixtures' own tone sets at the fixtures' own
level, perform the gesture, and assert on what the check says. Stdlib only, like
the analyzer.

Run by hand; not in CI and not in a hook (the analyzer belongs to the by-hand UI
regression suite, per §53 and the repo's standing rule).
"""

import array
import importlib.util
import math
import os
import random
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("verify_mix", os.path.join(HERE, "verify-mix.py"))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)

RATE = 48000
BPM = 122.0

# The fixtures' own tone sets and level (make-dj-fixture-media.py): three tones
# per deck sharing a -12 dBFS budget. Using anything else would test a signal
# the suite never sees — and the whole zipper measurement rests on the fact that
# no fixture puts energy above 8900 Hz.
TONES = {
    "a": {"low": 55.0, "mid": 611.0, "high": 5300.0},
    "b": {"low": 87.0, "mid": 1290.0, "high": 8900.0},
}
PEAK = 0.25
PER_TONE = PEAK / 3


# How long the engine's fader takes to reach its new value. The channel gains
# are one-pole smoothed on the render thread precisely so a fast move does not
# step (§35A, the mixer's smoothed gains), and 5 ms is 1% of a beat at 122 BPM —
# instant as far as "inside one beat" is concerned. Rendering the cut as a jump
# instead would be rendering the defect: the check catches it, correctly, and
# the test would be asserting that a broken fader passes.
CUT_RAMP_MS = 5.0


def render(seconds: float, cut_at: float = None, cut_deck: str = "a",
           residual: float = 0.0006, quiet_after: float = None, dither: float = 1.0,
           ramp_ms: float = CUT_RAMP_MS):
    """Two decks of steady tones, optionally cutting one deck's channel.

    `residual` is what survives a cut: a real cut leaves the other deck's tones
    bleeding into the cut deck's bins, which is why the check measures a fall
    rather than silence. `dither` is the codec noise floor every real recording
    has and no sum of sines does — without it the analyzer would be calibrating
    against arithmetic. `quiet_after` drops everything to near silence, for the
    case that used to saturate the old flatness measure. `ramp_ms=0` gives the
    unsmoothed fader, which is a zipper by definition.
    """
    total = int(seconds * RATE)
    ramp = max(0, int(ramp_ms / 1000.0 * RATE))

    def cut_gain(i):
        if cut_at is None:
            return 1.0
        start = cut_at * RATE
        if i < start:
            return 1.0
        if ramp and i < start + ramp:
            return 1.0 + (residual - 1.0) * (i - start) / ramp
        return residual

    acc = [0.0] * total
    for deck, bands in TONES.items():
        cut_this_deck = deck == cut_deck
        for freq in bands.values():
            w = 2.0 * math.pi * freq / RATE
            for i in range(total):
                gain = cut_gain(i) if cut_this_deck else 1.0
                if quiet_after is not None and i >= quiet_after * RATE:
                    # Ramped for the same reason the cut is: the passage going
                    # quiet is a fader move too, and a step here would be the
                    # defect rather than the scenario.
                    fade = min(1.0, (i - quiet_after * RATE) / max(1, ramp))
                    gain *= 1.0 + (0.0008 - 1.0) * fade
                acc[i] += PER_TONE * 32767 * gain * math.sin(w * i)

    rng = random.Random(3)
    samples = array.array("h", bytes(2 * total))
    for i in range(total):
        v = acc[i] + (rng.random() * 2 - 1) * dither
        samples[i] = int(max(-32768, min(32767, v)))
    return samples


def add_zipper(samples, at_seconds: float, step_fraction: float = 0.05,
               hold_ms: float = 40.0):
    """A fader that jumps instead of ramping: a step discontinuity.

    This is what the check is for. The step is what makes the click — its size
    is the deck's instantaneous level at the moment the fader moved.
    """
    start = int(at_seconds * RATE)
    offset = step_fraction * 32767
    for i in range(start, min(len(samples), start + int(hold_ms / 1000.0 * RATE))):
        samples[i] = int(max(-32768, min(32767, samples[i] + offset)))


def add_click(samples, at_seconds: float, amplitude: float, width_ms: float):
    """A broadband burst — the other shape a glitch takes."""
    rng = random.Random(11)
    start = int(at_seconds * RATE)
    for i in range(max(1, int(width_ms / 1000.0 * RATE))):
        v = samples[start + i] + amplitude * 32767 * (rng.random() * 2 - 1)
        samples[start + i] = int(max(-32768, min(32767, v)))


def add_segment_joins(samples, period_seconds: float = 30.0):
    """The artifact the old rule mistook for a click.

    The finished mix is a concatenation of 30-second AAC segments, decoded and
    re-encoded by `M4AJoiner`. Measured on the kept recording, each join leaves
    the off-tone floor a little higher for a few milliseconds — no dropout, no
    discontinuity, peak sample-to-sample step at or below the file's median.
    Modelled here as exactly that: a few LSB of extra noise, not a transient.
    """
    rng = random.Random(5)
    t = period_seconds
    while int(t * RATE) < len(samples) - RATE // 10:
        start = int(t * RATE)
        for i in range(int(0.02 * RATE)):
            v = samples[start + i] + (rng.random() * 2 - 1) * 3.0
            samples[start + i] = int(max(-32768, min(32767, v)))
        t += period_seconds


def cut_event(at_seconds: float, deck: str = "a"):
    return {"kind": "transition.faderCut", "outgoing": deck,
            "atSample": int(at_seconds * RATE)}


class FaderCutTests(unittest.TestCase):

    def test_clean_cut_passes(self):
        samples = render(24.0, cut_at=12.0)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(12.0), TONES)
        self.assertTrue(ok, note)
        self.assertIn("dB inside one beat", note)

    def test_a_cut_that_does_not_fall_far_enough_fails(self):
        # Down ~20 dB, not 30: the fader moved, the channel did not go away.
        samples = render(24.0, cut_at=12.0, residual=0.1)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(12.0), TONES)
        self.assertFalse(ok)
        self.assertIn("fell only", note)

    def test_a_stepping_fader_is_caught(self):
        samples = render(24.0, cut_at=12.0)
        add_zipper(samples, 12.0, step_fraction=0.05)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(12.0), TONES)
        self.assertFalse(ok)
        self.assertIn("zipper", note)

    def test_an_unsmoothed_fader_is_itself_a_zipper(self):
        """The defect this check exists for, in its own right.

        Drop the channel gain in one sample instead of ramping it and the cut
        clicks — which is why the mixer smooths its gains. Rendering the fixture
        that way was the first cut of these tests, and the check was right to
        fail it.
        """
        samples = render(24.0, cut_at=12.05, ramp_ms=0.0)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(12.05), TONES)
        self.assertFalse(ok)
        self.assertIn("zipper", note)

    def test_a_click_at_the_cut_is_caught(self):
        samples = render(24.0, cut_at=12.0)
        add_click(samples, 12.0, amplitude=0.02, width_ms=1.0)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(12.0), TONES)
        self.assertFalse(ok)
        self.assertIn("zipper", note)

    def test_segment_joins_are_not_zippers(self):
        """The 2026-08-16 false positive, pinned.

        A cut landing on a segment join used to fail the whole gate, and the gate
        is REQUIRED, so the milestone's exit item hung on it.
        """
        samples = render(90.0, cut_at=60.0)
        add_segment_joins(samples)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(60.0), TONES)
        self.assertTrue(ok, f"a segment join was called a zipper: {note}")

    def test_a_cut_into_a_quiet_passage_is_not_a_zipper(self):
        """The other landmine in the old measure.

        Spectral flatness saturates at 1.0 in near-silence, so a cut into a quiet
        passage read as a maximal broadband transient. A quiet passage has no
        off-tone energy, so the measure now sees a quiet passage.
        """
        samples = render(24.0, cut_at=12.0, quiet_after=12.0)
        ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(12.0), TONES)
        self.assertTrue(ok, f"a quiet passage was called a zipper: {note}")

    def test_the_measurement_is_not_beat_phase_sensitive(self):
        """Why the levels are span-averaged (the §14 fix, applied here at last).

        The fixtures are amplitude-modulated on their own beat while the mark
        sits on the master clock's, so a single 85 ms window lands at an
        arbitrary point in the envelope. The verdict must not depend on where.
        """
        beat = 60.0 / BPM
        for offset in (0.0, beat / 4, beat / 2, 3 * beat / 4):
            with self.subTest(offset=offset):
                at = 12.0 + offset
                samples = render(24.0, cut_at=at)
                ok, note = vm.check_fader_cut(samples, RATE, BPM, cut_event(at), TONES)
                self.assertTrue(ok, note)


class OffToneBaselineTests(unittest.TestCase):

    def test_the_floor_is_the_recording_not_a_constant(self):
        quiet_floor = render(20.0, dither=1.0)
        noisy_floor = render(20.0, dither=20.0)
        self.assertGreater(vm.off_tone_baseline(noisy_floor, RATE),
                           vm.off_tone_baseline(quiet_floor, RATE) * 10)

    def test_a_handful_of_glitches_cannot_raise_the_bar_that_catches_them(self):
        clean = render(60.0)
        clicky = render(60.0)
        for t in (10.0, 20.0, 30.0):
            add_click(clicky, t, amplitude=0.2, width_ms=1.0)
        # A median over the file, not a mean: three loud windows out of twelve
        # move it by nothing worth measuring.
        base = vm.off_tone_baseline(clean, RATE)
        self.assertLess(abs(vm.off_tone_baseline(clicky, RATE) - base), base * 0.5)

    def test_fixture_tones_leave_the_off_tone_band_empty(self):
        """The premise the whole measure rests on, asserted rather than assumed.

        If a fixture ever gains a tone up here — a new marker, a serial tone
        moved — this fails, and the probe set has to move rather than the
        threshold.
        """
        samples = render(10.0, dither=0.0)
        for start in (RATE, 3 * RATE, 5 * RATE):
            off = vm.off_tone_energy(samples, start, RATE)
            inband = vm.tone_energy(samples, start, RATE, TONES)
            self.assertLess(off, inband * vm.ZIPPER_FLOOR)


if __name__ == "__main__":
    unittest.main(verbosity=2)
