import XCTest

@testable import TonearmCore

final class CloudDriveAPITests: XCTestCase {

    func testDropboxListAndTemporaryLinkRequests() throws {
        let list = try CloudDriveAPI.request(provider: .dropbox, endpoint: .list(containerID: "id:folder"), accessToken: "token")
        let listBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(list.httpBody)) as? [String: Any])

        XCTAssertEqual(list.url?.absoluteString, "https://api.dropboxapi.com/2/files/list_folder")
        XCTAssertEqual(list.httpMethod, "POST")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(listBody["path"] as? String, "id:folder")
        XCTAssertEqual(listBody["recursive"] as? Bool, false)

        let link = try CloudDriveAPI.request(provider: .dropbox, endpoint: .resolveFile(id: "id:file", path: nil), accessToken: "token")
        XCTAssertEqual(link.url?.absoluteString, "https://api.dropboxapi.com/2/files/get_temporary_link")
    }

    func testGoogleDriveRequestsUseReadonlyDriveEndpoints() throws {
        let list = try CloudDriveAPI.request(provider: .googleDrive, endpoint: .list(containerID: "folder 1"), accessToken: "token")
        let listComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(list.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (listComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(listComponents.host, "www.googleapis.com")
        XCTAssertEqual(listComponents.path, "/drive/v3/files")
        XCTAssertEqual(query["q"], "'folder 1' in parents and trashed = false")
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer token")

        let media = try CloudDriveAPI.request(provider: .googleDrive, endpoint: .resolveFile(id: "file 1", path: nil), accessToken: "token")
        let mediaComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(media.url), resolvingAgainstBaseURL: false))
        let mediaQuery = Dictionary(uniqueKeysWithValues: (mediaComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(mediaComponents.percentEncodedPath, "/drive/v3/files/file%201")
        XCTAssertEqual(mediaQuery["alt"], "media")
    }

    func testOneDriveRequestsUseGraphChildrenAndContent() throws {
        let root = try CloudDriveAPI.request(provider: .oneDrive, endpoint: .list(containerID: nil), accessToken: "token")
        let child = try CloudDriveAPI.request(provider: .oneDrive, endpoint: .list(containerID: "folder 1"), accessToken: "token")
        let content = try CloudDriveAPI.request(provider: .oneDrive, endpoint: .resolveFile(id: "file 1", path: nil), accessToken: "token")

        XCTAssertEqual(root.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/root/children")
        XCTAssertEqual(child.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/items/folder%201/children")
        XCTAssertEqual(content.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/items/file%201/content")
        XCTAssertEqual(root.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(content.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testPCloudRequestsUseBearerAuthAndFolderIDs() throws {
        let list = try CloudDriveAPI.request(provider: .pCloud, endpoint: .list(containerID: "12345"), accessToken: "token")
        let resolve = try CloudDriveAPI.request(provider: .pCloud, endpoint: .resolveFile(id: "67890", path: nil), accessToken: "token")

        XCTAssertEqual(list.url?.absoluteString, "https://api.pcloud.com/listfolder?folderid=12345")
        XCTAssertEqual(resolve.url?.absoluteString, "https://api.pcloud.com/getfilelink?fileid=67890")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testDecodesDropboxListingAndFiltersAudio() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .dropbox, data: data("""
        {
          "entries": [
            { ".tag": "folder", "id": "id:folder", "name": "Albums", "path_lower": "/albums" },
            { ".tag": "file", "id": "id:file", "name": "Track.flac", "path_lower": "/albums/track.flac", "size": 1234 },
            { ".tag": "file", "id": "id:cover", "name": "cover.jpg", "path_lower": "/albums/cover.jpg", "size": 99 }
          ]
        }
        """))

        XCTAssertEqual(items[0].kind, .folder)
        XCTAssertTrue(items[1].isAudio)
        XCTAssertFalse(items[2].isAudio)
        XCTAssertEqual(items[1].sizeBytes, 1_234)
    }

    func testDecodesGoogleDriveListing() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .googleDrive, data: data("""
        {
          "files": [
            { "id": "folder-1", "name": "Albums", "mimeType": "application/vnd.google-apps.folder" },
            { "id": "file-1", "name": "Song.m4a", "mimeType": "audio/mp4", "size": "5678" }
          ]
        }
        """))

        XCTAssertEqual(items[0].kind, .folder)
        XCTAssertEqual(items[1].contentType, "audio/mp4")
        XCTAssertEqual(items[1].sizeBytes, 5_678)
        XCTAssertTrue(items[1].isAudio)
    }

    func testDecodesOneDriveListingWithDownloadURL() throws {
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

        XCTAssertEqual(items[0].kind, .folder)
        XCTAssertEqual(items[1].temporaryURL?.absoluteString, "https://download.example.com/song.mp3")
        XCTAssertTrue(items[1].isAudio)
    }

    func testDecodesPCloudListingAndResolvedLink() throws {
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

        XCTAssertEqual(items[0].id, "10")
        XCTAssertEqual(items[1].sizeBytes, 3_456)
        XCTAssertEqual(resolved.url.absoluteString, "https://c123.pcloud.com/dl/abc/Song.ogg")
        XCTAssertEqual(resolved.sizeBytes, 3_456)
    }

    func testDropboxResolvedLinkCarriesSize() throws {
        let resolved = try CloudDriveAPI.decodeResolvedAsset(provider: .dropbox, data: data("""
        {
          "metadata": { ".tag": "file", "name": "Song.flac", "id": "id:file", "size": 12345 },
          "link": "https://dl.dropboxusercontent.com/temp/song.flac"
        }
        """))

        XCTAssertEqual(resolved.url.absoluteString, "https://dl.dropboxusercontent.com/temp/song.flac")
        XCTAssertEqual(resolved.sizeBytes, 12_345)
    }

    func testBoxRequestsUseFixedRootIdAndContentEndpoint() throws {
        let root = try CloudDriveAPI.request(provider: .box, endpoint: .list(containerID: nil), accessToken: "token")
        let rootComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(root.url), resolvingAgainstBaseURL: false))
        let rootQuery = Dictionary(uniqueKeysWithValues: (rootComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(rootComponents.path, "/2.0/folders/0/items")
        XCTAssertEqual(rootQuery["limit"], "1000")
        XCTAssertEqual(root.value(forHTTPHeaderField: "Authorization"), "Bearer token")

        let child = try CloudDriveAPI.request(provider: .box, endpoint: .list(containerID: "123"), accessToken: "token")
        XCTAssertTrue(child.url?.absoluteString.hasPrefix("https://api.box.com/2.0/folders/123/items") ?? false)

        let content = try CloudDriveAPI.request(provider: .box, endpoint: .resolveFile(id: "456", path: nil), accessToken: "token")
        XCTAssertEqual(content.url?.absoluteString, "https://api.box.com/2.0/files/456/content")
        XCTAssertEqual(content.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testDecodesBoxListing() throws {
        let items = try CloudDriveAPI.decodeListing(provider: .box, data: data("""
        {
          "entries": [
            { "type": "folder", "id": "111", "name": "Albums" },
            { "type": "file", "id": "222", "name": "Song.flac", "size": 7890 }
          ]
        }
        """))

        XCTAssertEqual(items[0].kind, .folder)
        XCTAssertEqual(items[1].id, "222")
        XCTAssertEqual(items[1].sizeBytes, 7_890)
        XCTAssertTrue(items[1].isAudio)
    }

    func testBoxResolvedAssetIsUnsupportedLikeGoogleAndOneDrive() {
        XCTAssertThrowsError(try CloudDriveAPI.decodeResolvedAsset(provider: .box, data: data("{}"))) { error in
            XCTAssertEqual(error as? CloudDriveAPI.Error, .unsupportedProvider)
        }
    }

    func testYandexDiskRequestsUseResourcesEndpointAndDiskRootPath() throws {
        let root = try CloudDriveAPI.request(provider: .yandexDisk, endpoint: .list(containerID: nil), accessToken: "token")
        let rootComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(root.url), resolvingAgainstBaseURL: false))
        let rootQuery = Dictionary(uniqueKeysWithValues: (rootComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(rootComponents.path, "/v1/disk/resources")
        XCTAssertEqual(rootQuery["path"], "disk:/")
        XCTAssertEqual(root.value(forHTTPHeaderField: "Authorization"), "Bearer token")

        let child = try CloudDriveAPI.request(provider: .yandexDisk, endpoint: .list(containerID: "disk:/Music"), accessToken: "token")
        let childComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(child.url), resolvingAgainstBaseURL: false))
        let childQuery = Dictionary(uniqueKeysWithValues: (childComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(childQuery["path"], "disk:/Music")

        let download = try CloudDriveAPI.request(provider: .yandexDisk, endpoint: .resolveFile(id: "disk:/Music/song.mp3", path: nil), accessToken: "token")
        let downloadComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(download.url), resolvingAgainstBaseURL: false))
        let downloadQuery = Dictionary(uniqueKeysWithValues: (downloadComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(downloadComponents.path, "/v1/disk/resources/download")
        XCTAssertEqual(downloadQuery["path"], "disk:/Music/song.mp3")
    }

    func testDecodesYandexDiskListingFromEmbeddedItems() throws {
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

        XCTAssertEqual(items[0].kind, .folder)
        XCTAssertEqual(items[0].id, "disk:/Music/Albums")
        XCTAssertEqual(items[1].sizeBytes, 2_468)
        XCTAssertTrue(items[1].isAudio)
    }

    func testYandexDiskResolvedAssetDecodesHref() throws {
        let resolved = try CloudDriveAPI.decodeResolvedAsset(provider: .yandexDisk, data: data("""
        { "href": "https://downloader.dst.yandex.ru/disk/abc/Song.mp3", "method": "GET", "templated": false }
        """), fallbackSize: 9_999)

        XCTAssertEqual(resolved.url.absoluteString, "https://downloader.dst.yandex.ru/disk/abc/Song.mp3")
        XCTAssertEqual(resolved.sizeBytes, 9_999)
    }

    func testMalformedResponsesThrowProviderErrors() {
        XCTAssertThrowsError(try CloudDriveAPI.decodeListing(provider: .dropbox, data: data("{}"))) { error in
            XCTAssertEqual(error as? CloudDriveAPI.Error, .missingField("entries"))
        }
        XCTAssertThrowsError(try CloudDriveAPI.decodeListing(provider: .googleDrive, data: data("not-json"))) { error in
            XCTAssertEqual(error as? CloudDriveAPI.Error, .malformedResponse)
        }
        XCTAssertThrowsError(try CloudDriveAPI.decodeResolvedAsset(provider: .googleDrive, data: data("{}"))) { error in
            XCTAssertEqual(error as? CloudDriveAPI.Error, .unsupportedProvider)
        }
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
