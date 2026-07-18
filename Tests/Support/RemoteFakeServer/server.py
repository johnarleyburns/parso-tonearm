#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse
import base64
import json
import os


AUDIO_BYTES = b"tonearm-remote-test-audio"


class Handler(BaseHTTPRequestHandler):
    server_version = "TonearmRemoteFake/1.0"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            return self.send_json({"ok": True})

        if path.startswith("/oauth/") and path.endswith("/authorize"):
            return self.authorize(path, query)

        if path.endswith("/audio/test.flac") or path.endswith("/stream") or path.endswith("/content"):
            return self.send_bytes(AUDIO_BYTES, "audio/flac")

        if path.startswith("/dropbox/"):
            return self.send_json({"error": "dropbox uses post"}, status=405)

        if path.startswith("/googleDrive/drive/v3/files"):
            if not self.require_cloud_auth("googleDrive"):
                return
            return self.google_drive(path, query)

        if path.startswith("/oneDrive/v1.0/me/drive"):
            if not self.require_cloud_auth("oneDrive"):
                return
            return self.one_drive(path)

        if path.startswith("/pCloud/listfolder"):
            if not self.require_cloud_auth("pCloud"):
                return
            return self.pcloud_list(query)

        if path.startswith("/pCloud/getfilelink"):
            if not self.require_cloud_auth("pCloud"):
                return
            return self.send_json({"result": 0, "hosts": [self.headers.get("Host", "127.0.0.1:18089")], "path": "/pCloud/audio/test.flac"})

        if path.startswith("/subsonic/rest/"):
            if not self.require_subsonic_auth(query):
                return
            return self.subsonic(path)

        if path.startswith("/jellyfin/"):
            if not self.require_jellyfin_auth():
                return
            return self.jellyfin(path)

        if path.startswith("/plex/"):
            if not self.require_plex_auth():
                return
            return self.plex(path)

        return self.send_json({"error": "not found", "path": path}, status=404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))

        if path.startswith("/oauth/") and path.endswith("/token"):
            provider = path.split("/")[2]
            return self.oauth_token(provider, body)

        if path.startswith("/dropbox/2/files/list_folder"):
            if not self.require_cloud_auth("dropbox"):
                return
            return self.send_json({
                "entries": [
                    {".tag": "folder", "id": "id:albums", "name": "Albums", "path_lower": "/albums"},
                    {".tag": "file", "id": "id:track", "name": "Track.flac", "path_lower": "/track.flac", "size": len(AUDIO_BYTES)},
                ]
            })

        if path.startswith("/dropbox/2/files/get_temporary_link"):
            if not self.require_cloud_auth("dropbox"):
                return
            host = self.headers.get("Host", "127.0.0.1:18089")
            return self.send_json({
                "metadata": {".tag": "file", "id": "id:track", "name": "Track.flac", "size": len(AUDIO_BYTES)},
                "link": f"http://{host}/dropbox/audio/test.flac"
            })

        if path == "/jellyfin/Users/AuthenticateByName":
            if not self.require_jellyfin_client_auth():
                return
            return self.send_json({
                "AccessToken": "jellyfin-token",
                "ServerId": "server-1",
                "User": {"Id": "user-1", "Name": "alice"}
            })

        return self.send_json({"error": "not found", "path": path}, status=404)

    def do_PROPFIND(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/webdav"):
            return self.send_json({"error": "not found"}, status=404)
        if not self.require_webdav_auth():
            return
        body = """<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/webdav/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:displayname>Music</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/webdav/Track.flac</d:href>
    <d:propstat><d:prop><d:resourcetype/><d:displayname>Track.flac</d:displayname><d:getcontentlength>25</d:getcontentlength><d:getcontenttype>audio/flac</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>"""
        return self.send_bytes(body.encode("utf-8"), "application/xml; charset=utf-8", status=207)

    def authorize(self, path, query):
        redirect = query.get("redirect_uri", ["tonearm://oauth/callback"])[0]
        state = query.get("state", [""])[0]
        location = redirect + "?" + urlencode({"code": "code-1", "state": state})
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def oauth_token(self, provider, body):
        form = parse_qs(body.decode("utf-8"))
        grant = form.get("grant_type", ["authorization_code"])[0]

        if grant == "refresh_token":
            refresh_token = form.get("refresh_token", [""])[0]
            if refresh_token != f"{provider}-refresh":
                return self.send_json(
                    {"error": "invalid_grant", "error_description": "invalid refresh token"},
                    status=400,
                )

        suffix = "refreshed" if grant == "refresh_token" else "initial"
        response = {
            "access_token": f"{provider}-access-{suffix}",
            "refresh_token": f"{provider}-refresh",
            "token_type": "Bearer",
            "expires_in": 3600,
            "account_id": f"{provider}-account",
            "api_base_url": f"http://{self.headers.get('Host', '127.0.0.1:18089')}/{provider}",
        }
        if provider == "pCloud":
            response.pop("expires_in")
            response["uid"] = 123
        return self.send_json(response)

    def require_cloud_auth(self, provider):
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {provider}-access-"
        if expected not in auth:
            return self.send_json({"error": "unauthorized"}, status=401)
        return True

    def require_subsonic_auth(self, query):
        u = query.get("u", [""])[0]
        t = query.get("t", [""])[0]
        s = query.get("s", [""])[0]
        if u != "alice" or not t or not s:
            return self.send_json(
                {"subsonic-response": {"status": "failed", "error": {"code": 40, "message": "Wrong username or password"}}},
                status=401,
            )
        return True

    def require_jellyfin_auth(self):
        header = self.headers.get("X-Emby-Authorization", "")
        if 'Token="jellyfin-token"' not in header:
            return self.send_json({"error": "unauthorized"}, status=401)
        return True

    def require_jellyfin_client_auth(self):
        header = self.headers.get("X-Emby-Authorization", "")
        if not header.startswith("MediaBrowser Client="):
            return self.send_json({"error": "unauthorized"}, status=401)
        return True

    def require_plex_auth(self):
        token = self.headers.get("X-Plex-Token", "")
        if token != "plex-token":
            return self.send_json({"error": "unauthorized"}, status=401)
        return True

    def require_webdav_auth(self):
        auth = self.headers.get("Authorization", "")
        expected = base64.b64encode(b"alice:secret").decode("utf-8")
        if auth != f"Basic {expected}":
            return self.send_json({"error": "unauthorized"}, status=401)
        return True

    def google_drive(self, path, query):
        if path.rstrip("/").endswith("/files"):
            return self.send_json({
                "files": [
                    {"id": "folder-1", "name": "Albums", "mimeType": "application/vnd.google-apps.folder"},
                    {"id": "file-1", "name": "Track.flac", "mimeType": "audio/flac", "size": str(len(AUDIO_BYTES))},
                ]
            })
        if query.get("alt") == ["media"]:
            return self.send_bytes(AUDIO_BYTES, "audio/flac")
        return self.send_json({"error": "not found"}, status=404)

    def one_drive(self, path):
        if path.endswith("/root/children") or path.endswith("/children"):
            return self.send_json({
                "value": [
                    {"id": "folder-1", "name": "Albums", "folder": {"childCount": 1}, "size": 0},
                    {"id": "file-1", "name": "Track.flac", "size": len(AUDIO_BYTES), "file": {"mimeType": "audio/flac"}},
                ]
            })
        if path.endswith("/content"):
            return self.send_bytes(AUDIO_BYTES, "audio/flac")
        return self.send_json({"error": "not found"}, status=404)

    def pcloud_list(self, query):
        return self.send_json({
            "result": 0,
            "metadata": {
                "contents": [
                    {"isfolder": True, "folderid": 10, "name": "Albums", "path": "/Albums"},
                    {"isfolder": False, "fileid": 11, "name": "Track.flac", "path": "/Track.flac", "size": len(AUDIO_BYTES), "contenttype": "audio/flac"},
                ]
            }
        })

    def subsonic(self, path):
        if path.endswith("/ping.view"):
            return self.send_json({"subsonic-response": {"status": "ok", "version": "1.16.1"}})
        if path.endswith("/getArtists.view") or path.endswith("/getIndexes.view"):
            return self.send_json({"subsonic-response": {"status": "ok", "artists": {"index": [{"artist": [{"id": "artist-1", "name": "Artist", "albumCount": 1}]}]}}})
        if path.endswith("/getArtist.view"):
            return self.send_json({"subsonic-response": {"status": "ok", "artist": {"id": "artist-1", "name": "Artist", "album": [{"id": "album-1", "name": "Album", "artist": "Artist", "songCount": 1}]}}})
        if path.endswith("/getAlbum.view"):
            return self.send_json({"subsonic-response": {"status": "ok", "album": {"id": "album-1", "name": "Album", "song": [{"id": "song-1", "title": "Track", "duration": 3, "size": len(AUDIO_BYTES), "suffix": "flac"}]}}})
        if path.endswith("/stream.view"):
            return self.send_bytes(AUDIO_BYTES, "audio/flac")
        return self.send_json({"subsonic-response": {"status": "failed", "error": {"code": 0, "message": "not found"}}}, status=404)

    def jellyfin(self, path):
        if path == "/jellyfin/Artists/AlbumArtists":
            return self.send_json({"Items": [{"Id": "artist-1", "Name": "Artist", "Type": "MusicArtist"}]})
        if path == "/jellyfin/Users/user-1/Items":
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            if query.get("IncludeItemTypes") == ["MusicAlbum"]:
                return self.send_json({"Items": [{"Id": "album-1", "Name": "Album", "Type": "MusicAlbum"}]})
            return self.send_json({"Items": [{"Id": "track-1", "Name": "Track", "Type": "Audio", "RunTimeTicks": 30000000, "Size": len(AUDIO_BYTES)}]})
        if path == "/jellyfin/Audio/track-1/stream":
            return self.send_bytes(AUDIO_BYTES, "audio/flac")
        return self.send_json({"error": "not found"}, status=404)

    def plex(self, path):
        if path == "/plex/library/sections":
            return self.send_xml('<MediaContainer><Directory key="1" title="Music" type="artist"/></MediaContainer>')
        if path == "/plex/library/sections/1/all":
            return self.send_xml('<MediaContainer><Directory ratingKey="artist-1" title="Artist" type="artist"/></MediaContainer>')
        if path == "/plex/library/metadata/artist-1/children":
            return self.send_xml('<MediaContainer><Directory ratingKey="album-1" title="Album" type="album"/></MediaContainer>')
        if path == "/plex/library/metadata/album-1/children":
            return self.send_xml('<MediaContainer><Track ratingKey="track-1" title="Track" type="track" duration="3000"><Media><Part key="/plex/audio/test.flac" size="25"/></Media></Track></MediaContainer>')
        if path == "/plex/library/metadata/track-1":
            return self.send_xml('<MediaContainer><Track ratingKey="track-1" title="Track" type="track" duration="3000"><Media><Part key="/plex/audio/test.flac" size="25"/></Media></Track></MediaContainer>')
        return self.send_json({"error": "not found"}, status=404)

    def send_json(self, value, status=200):
        data = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_xml(self, value, status=200):
        self.send_bytes(value.encode("utf-8"), "application/xml", status)

    def send_bytes(self, value, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(value)))
        self.end_headers()
        self.wfile.write(value)


def main():
    port = int(os.environ.get("PORT", "18089"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"remote fake server listening on {port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
