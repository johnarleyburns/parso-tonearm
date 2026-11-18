import Foundation
import Testing

@testable import TonearmCore

@Suite struct CloudDriveAPITests {

    @Test func testDropboxListAndTemporaryLinkRequests() throws {
        let list = try CloudDriveAPI.request(provider: .dropbox, endpoint: .list(containerID: "id:folder"), accessToken: "token")
        let listBodyData = try #require(list.httpBody)
        let listBody = try #require(try JSONSerialization.jsonObject(with: listBodyData) as? [String: Any])

        #expect(list.url?.absoluteString == "https://api.dropboxapi.com/2/files/list_folder")
        #expect(list.httpMethod == "POST")
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(listBody["path"] as? String == "id:folder")
        #expect(listBody["recursive"] as? Bool == false)

        let link = try CloudDriveAPI.request(provider: .dropbox, endpoint: .resolveFile(id: "id:file", path: nil), accessToken: "token")
        #expect(link.url?.absoluteString == "https://api.dropboxapi.com/2/files/get_temporary_link")
    }

    @Test func testGoogleDriveRequestsUseReadonlyDriveEndpoints() throws {
        let list = try CloudDriveAPI.request(provider: .googleDrive, endpoint: .list(containerID: "folder 1"), accessToken: "token")
        let listURL = try #require(list.url)
        let listComponents = try #require(URLComponents(url: listURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (listComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(listComponents.host == "www.googleapis.com")
        #expect(listComponents.path == "/drive/v3/files")
        #expect(query["q"] == "'folder 1' in parents and trashed = false")
        #expect(query["supportsAllDrives"] == "true")
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        let media = try CloudDriveAPI.request(provider: .googleDrive, endpoint: .resolveFile(id: "file 1", path: nil), accessToken: "token")
        let mediaURL = try #require(media.url)
        let mediaComponents = try #require(URLComponents(url: mediaURL, resolvingAgainstBaseURL: false))
        let mediaQuery = Dictionary(uniqueKeysWithValues: (mediaComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(mediaComponents.percentEncodedPath == "/drive/v3/files/file%201")
        #expect(mediaQuery["alt"] == "media")
    }

    @Test func testOneDriveRequestsUseGraphChildrenAndContent() throws {
        let root = try CloudDriveAPI.request(provider: .oneDrive, endpoint: .list(containerID: nil), accessToken: "token")
        let child = try CloudDriveAPI.request(provider: .oneDrive, endpoint: .list(containerID: "folder 1"), accessToken: "token")
        let content = try CloudDriveAPI.request(provider: .oneDrive, endpoint: .resolveFile(id: "file 1", path: nil), accessToken: "token")

        #expect(root.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root/children")
        #expect(child.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/folder%201/children")
        #expect(content.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/file%201/content")
        #expect(root.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(content.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func testPCloudRequestsUseBearerAuthAndFolderIDs() throws {
        let list = try CloudDriveAPI.request(provider: .pCloud, endpoint: .list(containerID: "12345"), accessToken: "token")
        let resolve = try CloudDriveAPI.request(provider: .pCloud, endpoint: .resolveFile(id: "67890", path: nil), accessToken: "token")

        #expect(list.url?.absoluteString == "https://api.pcloud.com/listfolder?folderid=12345")
        #expect(resolve.url?.absoluteString == "https://api.pcloud.com/getfilelink?fileid=67890")
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func testDecodesDropboxListingAndFiltersAudio() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .dropbox, data: data("""
        {
          "entries": [
            { ".tag": "folder", "id": "id:folder", "name": "Albums", "path_lower": "/albums" },
            { ".tag": "file", "id": "id:file", "name": "Track.flac", "path_lower": "/albums/track.flac", "size": 1234 },
            { ".tag": "file", "id": "id:cover", "name": "cover.jpg", "path_lower": "/albums/cover.jpg", "size": 99 }
          ]
        }
        """))

        #expect(items[0].kind == .folder)
        #expect(items[1].isAudio)
        #expect(!items[2].isAudio)
        #expect(items[1].sizeBytes == 1_234)
        // Real report: a Dropbox track played fine on first stream, then never again once fully
        // cached — Dropbox's own API never returns a content type (unlike Google Drive's
        // `mimeType`), and the cached file's extensionless blob name gave AVFoundation no format
        // hint either. Derive it from the listing's own file name, the one place Dropbox does
        // carry the extension.
        #expect(items[1].contentType == "audio/flac")
    }

    @Test func testDecodesGoogleDriveListing() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .googleDrive, data: data("""
        {
          "files": [
            { "id": "folder-1", "name": "Albums", "mimeType": "application/vnd.google-apps.folder" },
            { "id": "file-1", "name": "Song.m4a", "mimeType": "audio/mp4", "size": "5678" }
          ]
        }
        """))

        #expect(items[0].kind == .folder)
        #expect(items[1].contentType == "audio/mp4")
        #expect(items[1].sizeBytes == 5_678)
        #expect(items[1].isAudio)
    }

    @Test func testDecodesOneDriveListingWithDownloadURL() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .oneDrive, data: data("""
        {
          "value": [
            { "id": "folder-1", "name": "Albums", "folder": { "childCount": 2 }, "size": 0 },
            { "id": "file-1", "name": "Song.mp3", "size": 9012,
              "file": { "mimeType": "audio/mpeg" },
              "@microsoft.graph.downloadUrl": "https://download.example.com/song.mp3" }
          ]
        }
        """))

        #expect(items[0].kind == .folder)
        #expect(items[1].temporaryURL?.absoluteString == "https://download.example.com/song.mp3")
        #expect(items[1].isAudio)
    }

    @Test func testDecodesPCloudListingAndResolvedLink() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .pCloud, data: data("""
        {
          "result": 0,
          "metadata": {
            "contents": [
              { "isfolder": true, "folderid": 10, "name": "Albums", "path": "/Albums" },
              { "isfolder": false, "fileid": 11, "name": "Song.ogg", "path": "/Albums/Song.ogg",
                "size": 3456, "contenttype": "audio/ogg" }
            ]
          }
        }
        """))
        let resolved = try CloudDriveAPI.decodeResolvedAsset(provider: .pCloud, data: data("""
        { "result": 0, "hosts": ["c123.pcloud.com"], "path": "/dl/abc/Song.ogg" }
        """), fallbackSize: items[1].sizeBytes)

        #expect(items[0].id == "10")
        #expect(items[1].sizeBytes == 3_456)
        #expect(resolved.url.absoluteString == "https://c123.pcloud.com/dl/abc/Song.ogg")
        #expect(resolved.sizeBytes == 3_456)
    }

    @Test func testDropboxResolvedLinkCarriesSize() throws {
        let resolved = try CloudDriveAPI.decodeResolvedAsset(provider: .dropbox, data: data("""
        {
          "metadata": { ".tag": "file", "name": "Song.flac", "id": "id:file", "size": 12345 },
          "link": "https://dl.dropboxusercontent.com/temp/song.flac"
        }
        """))

        #expect(resolved.url.absoluteString == "https://dl.dropboxusercontent.com/temp/song.flac")
        #expect(resolved.sizeBytes == 12_345)
    }

    @Test func testBoxRequestsUseFixedRootIdAndContentEndpoint() throws {
        let root = try CloudDriveAPI.request(provider: .box, endpoint: .list(containerID: nil), accessToken: "token")
        let rootURL = try #require(root.url)
        let rootComponents = try #require(URLComponents(url: rootURL, resolvingAgainstBaseURL: false))
        let rootQuery = Dictionary(uniqueKeysWithValues: (rootComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(rootComponents.path == "/2.0/folders/0/items")
        #expect(rootQuery["limit"] == "1000")
        #expect(root.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        let child = try CloudDriveAPI.request(provider: .box, endpoint: .list(containerID: "123"), accessToken: "token")
        #expect(child.url?.absoluteString.hasPrefix("https://api.box.com/2.0/folders/123/items") ?? false)

        let content = try CloudDriveAPI.request(provider: .box, endpoint: .resolveFile(id: "456", path: nil), accessToken: "token")
        #expect(content.url?.absoluteString == "https://api.box.com/2.0/files/456/content")
        #expect(content.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    /// Real report: Box login works, browsing and tapping play work, but it "spins for 30
    /// seconds even though it says 100% cached" — never actually plays. Root cause: Box's
    /// `/2.0/files/{id}/content` 302-redirects to a pre-signed, self-authenticating
    /// dl.boxcloud.com URL — a DIFFERENT host than api.box.com — but `resolve(node:)` used to
    /// hand back the api.box.com URL itself plus a Box OAuth bearer header (grouped with
    /// Google Drive/OneDrive, neither of which redirects cross-host). `CachingResourceLoader`
    /// resolves that redirect once, then reattaches the SAME bearer header to every later
    /// byte-range request against dl.boxcloud.com, which never expects it and can reject it.
    final class BoxRedirectStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var capturedCDNRequestHeaders: [String: String]?
        static let cdnURL = URL(string: "https://dl.boxcloud.com/d/1/final")!

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            if request.url?.host == "api.box.com" {
                let redirectResponse = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": Self.cdnURL.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.cdnURL),
                                     redirectResponse: redirectResponse)
                client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                Self.capturedCDNRequestHeaders = request.allHTTPHeaderFields
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                                httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    @Test func testBoxResolveFollowsTheRedirectItselfAndDropsTheBearerHeaderForTheCDNURL() async throws {
        BoxRedirectStub.capturedCDNRequestHeaders = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoxRedirectStub.self]
        let session = URLSession(configuration: config)

        let remote = CloudDriveProvider(provider: .box, accessToken: "box-token", session: session)
        let node = RemoteNode(id: "file:456", title: "Track", path: "file/456", kind: .audio)

        let resolved = try await remote.resolve(node: node)

        #expect(resolved.url == BoxRedirectStub.cdnURL)
        #expect(resolved.headers.isEmpty,
            "the boxcloud.com CDN URL is pre-signed and must never receive Tonearm's Box OAuth bearer header")
        #expect(BoxRedirectStub.capturedCDNRequestHeaders == nil,
            "resolve(node:) must decline the redirect itself, never actually fetch the CDN URL (let alone with a bearer header)")
    }

    @Test func testDecodesBoxListing() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .box, data: data("""
        {
          "entries": [
            { "type": "folder", "id": "111", "name": "Albums" },
            { "type": "file", "id": "222", "name": "Song.flac", "size": 7890 }
          ]
        }
        """))

        #expect(items[0].kind == .folder)
        #expect(items[1].id == "222")
        #expect(items[1].sizeBytes == 7_890)
        #expect(items[1].isAudio)
        // Same gap as Dropbox (see testDecodesDropboxListingAndFiltersAudio): Box's listing
        // never returns a content type either.
        #expect(items[1].contentType == "audio/flac")
    }

    @Test func testBoxResolvedAssetIsUnsupportedLikeGoogleAndOneDrive() {
        do {
            _ = try CloudDriveAPI.decodeResolvedAsset(provider: .box, data: data("{}"))
            Issue.record("expected decodeResolvedAsset(provider: .box) to throw")
        } catch {
            #expect(error as? CloudDriveAPI.Error == .unsupportedProvider)
        }
    }

    @Test func testYandexDiskRequestsUseResourcesEndpointAndDiskRootPath() throws {
        let root = try CloudDriveAPI.request(provider: .yandexDisk, endpoint: .list(containerID: nil), accessToken: "token")
        let rootURL = try #require(root.url)
        let rootComponents = try #require(URLComponents(url: rootURL, resolvingAgainstBaseURL: false))
        let rootQuery = Dictionary(uniqueKeysWithValues: (rootComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(rootComponents.path == "/v1/disk/resources")
        #expect(rootQuery["path"] == "disk:/")
        #expect(root.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        let child = try CloudDriveAPI.request(provider: .yandexDisk, endpoint: .list(containerID: "disk:/Music"), accessToken: "token")
        let childURL = try #require(child.url)
        let childComponents = try #require(URLComponents(url: childURL, resolvingAgainstBaseURL: false))
        let childQuery = Dictionary(uniqueKeysWithValues: (childComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(childQuery["path"] == "disk:/Music")

        let download = try CloudDriveAPI.request(provider: .yandexDisk, endpoint: .resolveFile(id: "disk:/Music/song.mp3", path: nil), accessToken: "token")
        let downloadURL = try #require(download.url)
        let downloadComponents = try #require(URLComponents(url: downloadURL, resolvingAgainstBaseURL: false))
        let downloadQuery = Dictionary(uniqueKeysWithValues: (downloadComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(downloadComponents.path == "/v1/disk/resources/download")
        #expect(downloadQuery["path"] == "disk:/Music/song.mp3")
    }

    @Test func testDecodesYandexDiskListingFromEmbeddedItems() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .yandexDisk, data: data("""
        {
          "name": "Music",
          "path": "disk:/Music",
          "type": "dir",
          "_embedded": {
            "items": [
              { "name": "Albums", "path": "disk:/Music/Albums", "type": "dir" },
              { "name": "Song.mp3", "path": "disk:/Music/Song.mp3", "type": "file",
                "size": 2468, "mime_type": "audio/mpeg" }
            ]
          }
        }
        """))

        #expect(items[0].kind == .folder)
        #expect(items[0].id == "disk:/Music/Albums")
        #expect(items[1].sizeBytes == 2_468)
        #expect(items[1].isAudio)
    }

    @Test func testYandexDiskResolvedAssetDecodesHref() throws {
        let resolved = try CloudDriveAPI.decodeResolvedAsset(provider: .yandexDisk, data: data("""
        { "href": "https://downloader.dst.yandex.ru/disk/abc/Song.mp3", "method": "GET", "templated": false }
        """), fallbackSize: 9_999)

        #expect(resolved.url.absoluteString == "https://downloader.dst.yandex.ru/disk/abc/Song.mp3")
        #expect(resolved.sizeBytes == 9_999)
    }

    @Test func testMalformedResponsesThrowProviderErrors() {
        do {
            _ = try CloudDriveAPI.decodeListing(provider: .dropbox, data: data("{}"))
            Issue.record("expected decodeListing(provider: .dropbox) with empty object to throw")
        } catch {
            #expect(error as? CloudDriveAPI.Error == .missingField("entries"))
        }
        do {
            _ = try CloudDriveAPI.decodeListing(provider: .googleDrive, data: data("not-json"))
            Issue.record("expected decodeListing(provider: .googleDrive) with non-JSON data to throw")
        } catch {
            #expect(error as? CloudDriveAPI.Error == .malformedResponse)
        }
        do {
            _ = try CloudDriveAPI.decodeResolvedAsset(provider: .googleDrive, data: data("{}"))
            Issue.record("expected decodeResolvedAsset(provider: .googleDrive) to throw")
        } catch {
            #expect(error as? CloudDriveAPI.Error == .unsupportedProvider)
        }
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
