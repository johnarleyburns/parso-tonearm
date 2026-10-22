#!/usr/bin/env python3
"""Generate local, phase-aware candidate plans for all 30 starter transitions."""

from __future__ import annotations

import argparse
import gzip
import json
import math
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import essentia.standard as es
import numpy as np


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Config" / "starter-blend-source.json"
AUDIO = ROOT / "linux-blender" / "audio"
OUT = ROOT / "linux-blender" / "plans" / "starter-transition-candidates.json"
SAMPLE_RATE = 44_100
OVERLAP_BEATS = 64
PHRASE_BEATS = 32
MAX_TEMPO_CHANGE = 0.08


@dataclass
class Analysis:
    track_id: str
    duration: float
    bpm: float
    period: float
    phase: float
    beats: list[float]
    drops: list[int]
    exits: list[int]
    rms_db: float


def decode_mono(path: Path) -> np.ndarray:
    process = subprocess.run([
        "ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-",
    ], check=True, stdout=subprocess.PIPE)
    return np.frombuffer(process.stdout, dtype=np.float32)


def snap(index: int, phase: int, modulo: int) -> int:
    return index + ((phase - index + modulo // 2) % modulo) - modulo // 2


def event_indices(level_db: np.ndarray, sign: float) -> list[int]:
    span, threshold = 8, 6.0
    scores = np.zeros(len(level_db))
    for index in range(span, len(level_db) - span):
        scores[index] = sign * (level_db[index:index + span].mean() - level_db[index - span:index].mean())
    events: list[int] = []
    for index in range(span, len(level_db) - span):
        neighborhood = scores[index - span:index + span]
        if scores[index] >= threshold and scores[index] >= neighborhood.max():
            events.append(index)
    return events


def analyze(track_id: str, catalog_bpm: float) -> Analysis:
    samples = decode_mono(AUDIO / f"{track_id}.m4a")
    duration = len(samples) / SAMPLE_RATE
    if not math.isfinite(catalog_bpm) or catalog_bpm <= 0:
        raise RuntimeError(f"{track_id}: invalid catalog BPM {catalog_bpm!r}")
    period = 60.0 / catalog_bpm
    # Bass energy per beat. These filters avoid allocating a whole-track FFT;
    # this is a candidate-plan structural signal, not a claim of native parity.
    bass = es.HighPass(cutoffFrequency=35, sampleRate=SAMPLE_RATE)(
        es.LowPass(cutoffFrequency=160, sampleRate=SAMPLE_RATE)(samples)
    )
    # The catalog BPM is the curation authority.  Search 192 phases against
    # the local low-band onset envelope rather than allowing a generic tracker
    # to reinterpret sparse ambient/acoustic arrangements at another tempo.
    hop = 256
    trimmed = bass[:len(bass) // hop * hop].reshape(-1, hop)
    envelope = np.sqrt(np.mean(trimmed * trimmed, axis=1))
    flux = np.maximum(0, np.diff(envelope, prepend=envelope[0]))
    rate = SAMPLE_RATE / hop
    phases = np.arange(192, dtype=np.float64) * period / 192
    beat_numbers = np.arange(int(duration / period) + 1, dtype=np.float64)
    scores = []
    for candidate in phases:
        indices = np.rint((candidate + beat_numbers * period) * rate).astype(int)
        indices = indices[(indices >= 0) & (indices < len(flux))]
        scores.append(float(flux[indices].sum()))
    phase = float(phases[int(np.argmax(scores))])
    beats = [float(phase + number * period) for number in beat_numbers if phase + number * period < duration]
    if len(beats) < 16:
        raise RuntimeError(f"{track_id}: catalog grid contains fewer than 16 beats")
    levels = []
    for start, end in zip(beats, beats[1:]):
        segment = bass[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)]
        levels.append(20 * math.log10(float(np.sqrt(np.mean(segment * segment))) + 1e-8))
    return Analysis(
        track_id=track_id, duration=duration, bpm=catalog_bpm, period=period, phase=phase,
        beats=beats, drops=event_indices(np.asarray(levels), 1), exits=event_indices(np.asarray(levels), -1),
        rms_db=20 * math.log10(float(np.sqrt(np.mean(samples * samples))) + 1e-8),
    )


def phrase_lines(analysis: Analysis) -> list[int]:
    events = analysis.drops + analysis.exits
    if events:
        phase = max(range(PHRASE_BEATS), key=lambda value: sum(1 for event in events if event % PHRASE_BEATS == value))
    else:
        phase = 0
    return [index for index in range(snap(0, phase, PHRASE_BEATS), len(analysis.beats), PHRASE_BEATS)
            if 0 <= index < len(analysis.beats)]


def point_before(indexes: list[int], limit: int, minimum: int) -> int | None:
    candidates = [index for index in indexes if minimum <= index <= limit]
    return max(candidates) if candidates else None


def plan(outgoing: Analysis, incoming: Analysis) -> dict:
    def phrase_cut(reason: str) -> dict:
        lines = phrase_lines(outgoing)
        cut = lines[-1] if lines else max(0, len(outgoing.beats) - 1)
        return {
            "style": "phrase-cut", "reason": reason,
            "outgoingCutBeat": cut, "incomingStartBeat": 0,
            "tempo": 1.0, "overlapBeats": 0,
        }

    ratio = incoming.period / outgoing.period
    if abs(ratio - 1) > MAX_TEMPO_CHANGE:
        return phrase_cut("tempo gap exceeds the 8% time-stretch limit")
    outgoing_lines = phrase_lines(outgoing)
    incoming_lines = phrase_lines(incoming)
    outgoing_limit = len(outgoing.beats) - OVERLAP_BEATS - 1
    safe_outgoing_lines = [line for line in outgoing_lines if PHRASE_BEATS <= line <= outgoing_limit]
    if not safe_outgoing_lines:
        return phrase_cut("outgoing track has no phrase line with room for a 64-beat overlap")
    outgoing_swap = (
        point_before(outgoing.drops, outgoing_limit, len(outgoing.beats) // 2)
        or point_before(outgoing.exits, outgoing_limit, PHRASE_BEATS)
        or max(safe_outgoing_lines)
    )
    incoming_swap = next((drop for drop in incoming.drops if drop >= PHRASE_BEATS), None)
    style = "double-drop" if incoming_swap is not None and outgoing_swap in outgoing.drops else "bass-swap"
    if incoming_swap is None:
        incoming_swap = next((line for line in incoming_lines if line >= PHRASE_BEATS), None)
    if incoming_swap is None or incoming_swap < OVERLAP_BEATS // 2:
        return phrase_cut("incoming track has no phase-safe 32-beat entry point")
    blend_start_beat = outgoing_swap - OVERLAP_BEATS // 2
    return {
        "style": style,
        "reason": "candidate phase plan from Essentia beat grid and bass-energy phrase markers",
        "tempo": ratio,
        "incomingGain": 10 ** ((outgoing.rms_db - incoming.rms_db) / 20),
        "overlapBeats": OVERLAP_BEATS,
        "outgoingSwapBeat": outgoing_swap,
        "incomingSwapBeat": incoming_swap,
        "blendStartSeconds": outgoing.beats[blend_start_beat],
        "swapSeconds": outgoing.beats[outgoing_swap],
        "blendEndSeconds": outgoing.beats[outgoing_swap + OVERLAP_BEATS // 2],
        "incomingOffsetSeconds": outgoing.beats[blend_start_beat] - incoming.beats[incoming_swap - OVERLAP_BEATS // 2] / ratio,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-index", required=True, type=Path,
                        help="pinned starter-v4 source-index.json.gz used for catalog BPM")
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text())
    ids = sorted({track for blend in catalog["blends"] for track in blend["tracks"]}, key=int)
    missing = [track_id for track_id in ids if not (AUDIO / f"{track_id}.m4a").exists()]
    if missing:
        print("missing AAC inputs; run fetch_starter_audio.py first: " + ", ".join(missing), file=sys.stderr)
        return 2
    with gzip.open(args.source_index, "rt") as source:
        records = json.load(source)
    catalog_bpm = {
        record["id"].removeprefix("jamendo-"): float(record["bpm"])
        for record in records
        if isinstance(record, dict) and isinstance(record.get("id"), str) and record.get("bpm") is not None
    }
    no_bpm = [track_id for track_id in ids if track_id not in catalog_bpm]
    if no_bpm:
        print("source index lacks catalog BPM for: " + ", ".join(no_bpm), file=sys.stderr)
        return 2
    analyses = {}
    for position, track_id in enumerate(ids, start=1):
        print(f"analyzing {position}/{len(ids)}: {track_id}", flush=True)
        analyses[track_id] = analyze(track_id, catalog_bpm[track_id])
    transitions = []
    for blend in catalog["blends"]:
        for index, (outgoing, incoming) in enumerate(zip(blend["tracks"], blend["tracks"][1:]), start=1):
            transitions.append({
                "blendID": blend["id"], "edge": index, "outgoing": outgoing, "incoming": incoming,
                "outgoingAnalysis": asdict(analyses[outgoing]), "incomingAnalysis": asdict(analyses[incoming]),
                "plan": plan(analyses[outgoing], analyses[incoming]),
            })
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "schemaVersion": 1, "plannerKind": "linux-candidate", "plannerVersion": "0.1.0",
        "sourceCatalog": str(CATALOG.relative_to(ROOT)), "sourceIndex": str(args.source_index),
        "transitionCount": len(transitions),
        "transitions": transitions,
    }, indent=2) + "\n")
    print(f"wrote {len(transitions)} candidate transitions to {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
