import XCTest

@testable import TonearmCore

final class WebDAVParserTests: XCTestCase {

    func testNextcloudPropfindEscapedNamesAndAudioFiltering() throws {
        let listing = try WebDAVParser.parse(data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/alice/Music/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/alice/Music/A%20%26%20B.flac</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>A &amp; B.flac</d:displayname>
                <d:getcontentlength>12345</d:getcontentlength>
                <d:getcontenttype>audio/flac</d:getcontenttype>
                <d:getlastmodified>Tue, 02 Jan 2024 10:00:00 GMT</d:getlastmodified>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/alice/Music/cover.jpg</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>cover.jpg</d:displayname>
                <d:getcontentlength>555</d:getcontentlength>
                <d:getcontenttype>image/jpeg</d:getcontenttype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """), basePath: "/remote.php/dav/files/alice/Music/")

        XCTAssertEqual(listing.path, "/remote.php/dav/files/alice/Music/")
        XCTAssertEqual(listing.entries.map(\.name), ["A & B.flac", "cover.jpg"])
        XCTAssertEqual(listing.entries.first?.relativePath, "A & B.flac")
        XCTAssertEqual(listing.entries.first?.contentLength, 12_345)
        XCTAssertEqual(listing.entries.first?.lastModified, "Tue, 02 Jan 2024 10:00:00 GMT")
        XCTAssertEqual(listing.playableEntries.map(\.name), ["A & B.flac"])
    }

    func testApacheDefaultNamespaceCollection() throws {
        let listing = try WebDAVParser.parse(data("""
        <multistatus xmlns="DAV:">
          <response>
            <href>/dav/music/</href>
            <propstat><prop><resourcetype><collection /></resourcetype></prop></propstat>
          </response>
          <response>
            <href>/dav/music/Album/</href>
            <propstat>
              <prop>
                <displayname>Album</displayname>
                <resourcetype><collection /></resourcetype>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        </multistatus>
        """), basePath: "/dav/music/")

        XCTAssertEqual(listing.entries, [
            WebDAVEntry(href: "/dav/music/Album/",
                        relativePath: "Album",
                        name: "Album",
                        kind: .directory,
                        contentLength: nil,
                        contentType: nil,
                        lastModified: nil)
        ])
        XCTAssertEqual(listing.playableEntries.map(\.name), ["Album"])
    }

    func testRcloneFullHrefFallsBackToFilename() throws {
        let listing = try WebDAVParser.parse(data("""
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>https://dav.example.test/music/Live/Track%2001.mp3</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>321</d:getcontentlength>
                <d:getcontenttype>application/octet-stream</d:getcontenttype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """), basePath: "/music/")

        XCTAssertEqual(listing.entries.first?.href, "/music/Live/Track 01.mp3")
        XCTAssertEqual(listing.entries.first?.relativePath, "Live/Track 01.mp3")
        XCTAssertEqual(listing.entries.first?.name, "Track 01.mp3")
        XCTAssertEqual(listing.playableEntries.map(\.relativePath), ["Live/Track 01.mp3"])
    }

    func testDeepNestedPathsRemainRelativeToBase() throws {
        let listing = try WebDAVParser.parse(data("""
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Music/Artist/Album/Disc%201/01%20Prelude.m4a</D:href>
            <D:propstat>
              <D:prop><D:getcontenttype>audio/mp4</D:getcontenttype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """), basePath: "/dav/")

        XCTAssertEqual(
            listing.entries.first?.relativePath,
            "Music/Artist/Album/Disc 1/01 Prelude.m4a"
        )
        XCTAssertEqual(listing.entries.first?.name, "01 Prelude.m4a")
    }

    func testEmptyCollectionSkipsSelfResponse() throws {
        let listing = try WebDAVParser.parse(data("""
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/empty/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection /></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """), basePath: "/dav/empty/")

        XCTAssertEqual(listing.entries, [])
    }

    func testUnsuccessfulResponsesAreIgnored() throws {
        let listing = try WebDAVParser.parse(data("""
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/music/Missing.flac</d:href>
            <d:propstat>
              <d:prop><d:getcontenttype>audio/flac</d:getcontenttype></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """), basePath: "/dav/music/")

        XCTAssertEqual(listing.entries, [])
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
