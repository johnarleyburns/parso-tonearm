#!/usr/bin/env python3
"""Write the UI regression suite's fixture audio.

One small, deterministic, license-free WAV, generated rather than committed so no
binary lands in the repo (§54.1). Every local backing server in
docker-compose.ui-regression.yml mounts the result.

The tone is a 5-second 440 Hz sine at -12 dBFS: long enough for a playback
assertion to observe the position advancing, short enough to keep the suite fast,
and unmistakable if it ever plays by accident.
"""

import math
import os
import struct
import sys
import wave

SAMPLE_RATE = 44_100
DURATION_SEC = 5.0
FREQ_HZ = 440.0
AMPLITUDE = 0.25  # ≈ -12 dBFS


def write_wav(path: str) -> None:
    frames = bytearray()
    for n in range(int(SAMPLE_RATE * DURATION_SEC)):
        value = AMPLITUDE * math.sin(2.0 * math.pi * FREQ_HZ * n / SAMPLE_RATE)
        frames += struct.pack("<h", int(value * 32767.0))

    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(bytes(frames))


def main() -> int:
    dest = sys.argv[1] if len(sys.argv) > 1 else "/media"
    os.makedirs(dest, exist_ok=True)
    path = os.path.join(dest, "Platterhead Regression Tone.wav")
    write_wav(path)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
