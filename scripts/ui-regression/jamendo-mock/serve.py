#!/usr/bin/env python3
"""A canned stand-in for the Jamendo v3.0 read API (spec §53.12).

Serves the genre/track shapes the `djmix` lane needs, plus the fixture WAVs, so the
**real browse UI path** — genre picker → genre library → per-deck playlists — is
exercised without depending on a third party being up.

    python3 serve.py --media /media --port 18092

The gating lane must mean the same thing on every run; the live lane
(`LANES=djlive`) is what checks the real endpoint shapes. Keep this mock's response
shape in step with `JamendoGenreProvider` — when the live lane catches a change, fix
both. **Endpoint shapes MUST be verified against developer.jamendo.com/v3.0 at
implementation time** (plan decision 20), not assumed from this file.

No credential lives here. The real `client_id` is an application credential that
belongs in `.test-credentials` and is used only by the live lane (§54.2, §54.5);
this mock accepts and ignores whatever is passed.
"""

import argparse
import json
import os
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# The genre tree the first-run picker offers (§41.1a). Sub-genres are distinct
# libraries, not filters on a parent — that is FR-LIB-9's shape.
GENRES = [
    {"id": "electronic", "name": "Electronic",
     "subgenres": [
         {"id": "techno", "name": "Techno"},
         {"id": "house", "name": "House"},
         {"id": "drumnbass", "name": "Drum & Bass"},
     ]},
    {"id": "hiphop", "name": "Hip-Hop",
     "subgenres": [
         {"id": "boombap", "name": "Boom Bap"},
         {"id": "trap", "name": "Trap"},
     ]},
    {"id": "rock", "name": "Rock", "subgenres": []},
]

MEDIA_DIR = "/media"


# Tracks per genre listing. Each genre gets its **own** window of the fixture
# set: two genres serving the same files would import as one crate, because the
# library dedupes on content hash and the second crate would just mirror the
# first — which is exactly the shape AT-MIX-2 ("two decks, two different
# playlists") is there to prove is not happening.
TRACKS_PER_GENRE = 6


def genre_window(tracks, genre: str):
    """The slice of the fixture set this genre's catalogue is drawn from.

    Keyed by a stable checksum of the genre id rather than Python's `hash`,
    which is salted per process — the catalogue must be identical on every run
    and across the mock's own restarts.
    """
    families = max(1, len(tracks) // TRACKS_PER_GENRE)
    start = (zlib.crc32(genre.encode("utf-8")) % families) * TRACKS_PER_GENRE
    return tracks[start:start + TRACKS_PER_GENRE]


def tracks_for(genre: str, limit: int, offset: int):
    """Fixture tracks presented as a genre listing, most-interesting descending.

    Deck roles alternate so a caller taking the top N gets both tone sets, which is
    what lets the lane build two playlists that will actually contrast.
    """
    manifest_path = os.path.join(MEDIA_DIR, "dj-fixture-manifest.json")
    if not os.path.exists(manifest_path):
        return []
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)

    catalogue = [t for t in manifest["tracks"] if "sync" not in t["file"]]
    rows = []
    for index, track in enumerate(genre_window(catalogue, genre)):
        rows.append({
            "id": f"{genre}-{index + 1}",
            "name": f"{genre.title()} Fixture {index + 1}",
            "artist_name": f"Regression Artist {track['toneRole'].upper()}",
            "album_name": "UI Regression Fixtures",
            "duration": int(track["durationSeconds"]),
            # Popularity descending — the "most interesting" ordering FR-LIB-9 needs.
            "popularity": 1000 - index,
            "audio": f"http://__HOST__/media/{track['file']}",
            "audiodownload": f"http://__HOST__/media/{track['file']}",
            "audiodownload_allowed": True,
            "license_ccurl": "https://creativecommons.org/licenses/by-sa/3.0/",
            "musicinfo": {"tags": {"genres": [genre]}},
            # Not part of Jamendo's schema — carried so the lane and the analyzer
            # can tell which tone set a track uses without a second copy of the table.
            "x_regression_tone_role": track["toneRole"],
            "x_regression_bpm": track["bpm"],
        })
    return rows[offset:offset + limit]


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # quieter output
        pass

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _headers_ok(self, results):
        return {"headers": {"status": "success", "code": 0, "error_message": "",
                            "results_count": len(results)},
                "results": results}

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        host = self.headers.get("Host", "127.0.0.1")

        if parsed.path.rstrip("/") in ("/v3.0/tags", "/v3.0/genres"):
            return self._json(self._headers_ok(GENRES))

        if parsed.path.rstrip("/") == "/v3.0/tracks":
            genre = (query.get("tags") or query.get("fuzzytags") or ["electronic"])[0]
            limit = int((query.get("limit") or ["20"])[0])
            offset = int((query.get("offset") or ["0"])[0])
            rows = tracks_for(genre, limit, offset)
            for row in rows:
                row["audio"] = row["audio"].replace("__HOST__", host)
                row["audiodownload"] = row["audiodownload"].replace("__HOST__", host)
            return self._json(self._headers_ok(rows))

        if parsed.path.startswith("/media/"):
            return self._serve_media(parsed.path[len("/media/"):])

        if parsed.path.rstrip("/") in ("", "/health"):
            return self._json({"status": "ok"})

        self._json({"headers": {"status": "failed", "code": 404,
                                "error_message": "not found"}, "results": []}, 404)

    def _serve_media(self, name: str):
        # Defend the media root: the lane controls these names, but a path-traversal
        # bug in a test server is still a path-traversal bug.
        safe = os.path.normpath(os.path.join(MEDIA_DIR, name))
        if not safe.startswith(os.path.abspath(MEDIA_DIR) + os.sep) or not os.path.isfile(safe):
            self.send_error(404)
            return
        size = os.path.getsize(safe)
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(safe, "rb") as handle:
            self.wfile.write(handle.read())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media", default="/media")
    parser.add_argument("--port", type=int, default=18092)
    args = parser.parse_args()

    global MEDIA_DIR
    MEDIA_DIR = os.path.abspath(args.media)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"jamendo-mock serving {MEDIA_DIR} on :{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
