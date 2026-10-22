# Linux starter-blend planner

This is the private, Linux-only curation tool for producing candidate
phase-aware plans for Tonearm's six starter runs. It is deliberately separate
from the iOS application and its shipping dependencies.

It uses Essentia for tempo/beat grids, `ffmpeg` for AAC decoding, and a
transparent implementation of the current Parso overlap policy:

- 64 beat overlap, with the bass swap after 32 beats;
- prefer a late outgoing drop or bass exit;
- start the incoming track at an early drop when available;
- otherwise snap both sides to a 32-beat phrase line;
- preserve the catalog's BPM compatibility rule (within 8%).

The output has `plannerKind: "linux-candidate"`. It is useful for local
listening/review, but is not represented as byte-for-byte equivalent to the
Apple-only `ParsoMixEngine.BlendPlanner` until a native parity suite exists.

## Run

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
export TONEARM_JAMENDO_CLIENT_ID='…'
.venv/bin/python scripts/fetch_starter_audio.py
.venv/bin/python scripts/generate_starter_plans.py \
  --source-index /path/to/starter-v4/source-index.json.gz
```

The source AAC files, decoded working data, virtual environment, and generated
plans are intentionally ignored. Review generated plans under `plans/` before
deciding whether to version a manifest.
