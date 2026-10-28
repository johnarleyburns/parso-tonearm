#!/usr/bin/env python3
"""Build an independently reviewable 128-D compressed CLAP audio candidate."""
from pathlib import Path
import sys

# The workflow deliberately runs this entry point with ``python -I``. Isolated
# mode omits the script directory, so add only this checked-in tool directory
# before importing its sibling implementation module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_candidate_common import main

if __name__ == "__main__":
    main("audio")
