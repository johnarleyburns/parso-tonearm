import XCTest
@testable import Tonearm

final class SourceFallbackIconTests: XCTestCase {

    private func makeSource(kind: SourceKind, localIsFolder: Bool = false) -> Source {
        Source(id: 1, kind: kind, iaIdentifier: nil, originalURL: nil,
               title: "Test", addedAt: Date(), lastResolvedAt: nil,
               followUpdates: false, licenseText: nil, memberCapHit: false,
               localIsFolder: localIsFolder)
    }

    func testLocalFilesIcon() {
        XCTAssertEqual(makeSource(kind: .local, localIsFolder: false).fallbackIcon,
                       "music.note.list")
    }

    func testLocalFolderIcon() {
        XCTAssertEqual(makeSource(kind: .local, localIsFolder: true).fallbackIcon,
                       "folder.fill")
    }

    func testIACollectionIcons() {
        XCTAssertEqual(makeSource(kind: .iaList).fallbackIcon, "square.stack.fill")
        XCTAssertEqual(makeSource(kind: .iaCollection).fallbackIcon, "square.stack.fill")
        XCTAssertEqual(makeSource(kind: .iaFavorites).fallbackIcon, "square.stack.fill")
    }

    func testIAItemIcon() {
        XCTAssertEqual(makeSource(kind: .iaItem).fallbackIcon, "music.note")
    }

    func testRemoteServerIcons() {
        XCTAssertEqual(makeSource(kind: .subsonic).fallbackIcon, "server.rack")
        XCTAssertEqual(makeSource(kind: .jellyfin).fallbackIcon, "server.rack")
        XCTAssertEqual(makeSource(kind: .plex).fallbackIcon, "server.rack")
    }

    func testRemoteStorageIcons() {
        let icon = "externaldrive.connected.to.line.below"
        XCTAssertEqual(makeSource(kind: .webDAV).fallbackIcon, icon)
        XCTAssertEqual(makeSource(kind: .smb).fallbackIcon, icon)
        XCTAssertEqual(makeSource(kind: .dropbox).fallbackIcon, icon)
        XCTAssertEqual(makeSource(kind: .googleDrive).fallbackIcon, icon)
        XCTAssertEqual(makeSource(kind: .oneDrive).fallbackIcon, icon)
        XCTAssertEqual(makeSource(kind: .pCloud).fallbackIcon, icon)
    }

    func testLocalFilesAndFolderIconsDiffer() {
        let files = makeSource(kind: .local, localIsFolder: false).fallbackIcon
        let folder = makeSource(kind: .local, localIsFolder: true).fallbackIcon
        let collection = makeSource(kind: .iaCollection).fallbackIcon
        XCTAssertNotEqual(files, folder)
        XCTAssertNotEqual(files, collection)
        XCTAssertNotEqual(folder, collection)
    }
}
