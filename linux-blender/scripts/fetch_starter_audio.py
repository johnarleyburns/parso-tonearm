#!/usr/bin/env python3
"""Fetch and transcode exactly the locally curated starter tracks.

The Jamendo client ID is read only from TONEARM_JAMENDO_CLIENT_ID.  Audio is
private working material in ../audio and is deliberately gitignored.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Config" / "starter-blend-source.json"
AUDIO = ROOT / "linux-blender" / "audio"
API = "https://api.jamendo.com/v3.0/tracks/"


def request_json(ids: list[str], client_id: str) -> dict:
    query = urllib.parse.urlencode({
        "client_id": client_id,
        "format": "json",
        "id": "+".join(ids),
        "audioformat": "mp32",
        "limit": "100",
    })
    with urllib.request.urlopen(f"{API}?{query}", timeout=60) as response:
        return json.load(response)


def main() -> int:
    client_id = os.environ.get("TONEARM_JAMENDO_CLIENT_ID")
    if not client_id:
        print("TONEARM_JAMENDO_CLIENT_ID is required", file=sys.stderr)
        return 2
    catalog = json.loads(CATALOG.read_text())
    ids = sorted({track for blend in catalog["blends"] for track in blend["tracks"]}, key=int)
    payload = request_json(ids, client_id)
    if payload.get("headers", {}).get("status") != "success":
        headers = payload.get("headers", {})
        print(f"Jamendo request was not successful (code={headers.get('code')}, message={headers.get('error_message')})", file=sys.stderr)
        return 1
    tracks = {str(track["id"]): track for track in payload["results"]}
    missing = sorted(set(ids) - tracks.keys(), key=int)
    if missing:
        print(f"Jamendo resolved {len(tracks)}/{len(ids)} tracks; missing: {', '.join(missing)}", file=sys.stderr)
        return 1

    AUDIO.mkdir(parents=True, exist_ok=True)
    for track_id in ids:
        target = AUDIO / f"{track_id}.m4a"
        if target.exists() and target.stat().st_size > 0:
            print(f"cached {track_id}")
            continue
        source_url = tracks[track_id].get("audio")
        if not isinstance(source_url, str) or not source_url.startswith("https://"):
            print(f"{track_id} has no HTTPS audio source", file=sys.stderr)
            return 1
        print(f"fetching/transcoding {track_id}")
        with tempfile.TemporaryDirectory(prefix="tonearm-starter-") as temp_dir:
            source = Path(temp_dir) / f"{track_id}.mp3"
            encoded = Path(temp_dir) / f"{track_id}.m4a"
            urllib.request.urlretrieve(source_url, source)
            subprocess.run([
                "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(source),
                "-map", "0:a:0", "-vn", "-map_metadata", "-1", "-c:a", "aac", "-profile:a", "aac_low",
                "-b:a", "128k", "-ar", "44100", "-ac", "2", "-movflags", "+faststart", str(encoded),
            ], check=True)
            encoded.replace(target)
    print(f"ready: {len(ids)} AAC tracks in {AUDIO}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
