#!/usr/bin/env python3
"""Build an independently reviewable 128-D compressed CLAP text candidate."""
from pathlib import Path
import sys

# See generate_candidate_audio.py: preserve isolated mode while allowing this
# audited entry point to import its checked-in sibling module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_candidate_common import main

if __name__ == "__main__":
    main("text")
