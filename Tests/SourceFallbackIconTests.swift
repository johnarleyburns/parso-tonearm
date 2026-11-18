import Foundation
import Testing
@testable import TonearmCore

@Suite struct SourceFallbackIconTests {

    private func makeSource(kind: SourceKind, localIsFolder: Bool = false) -> Source {
        Source(id: 1, kind: kind, iaIdentifier: nil, originalURL: nil,
               title: "Test", addedAt: Date(), lastResolvedAt: nil,
               followUpdates: false, licenseText: nil, memberCapHit: false,
               localIsFolder: localIsFolder)
    }

    @Test func testLocalFilesIcon() {
        #expect(makeSource(kind: .local, localIsFolder: false).fallbackIcon ==
                       "music.note.list")
    }

    @Test func testLocalFolderIcon() {
        #expect(makeSource(kind: .local, localIsFolder: true).fallbackIcon ==
                       "folder.fill")
    }

    @Test func testIACollectionIcons() {
        #expect(makeSource(kind: .iaList).fallbackIcon == "square.stack.fill")
        #expect(makeSource(kind: .iaCollection).fallbackIcon == "square.stack.fill")
        #expect(makeSource(kind: .iaFavorites).fallbackIcon == "square.stack.fill")
    }

    @Test func testIAItemIcon() {
        #expect(makeSource(kind: .iaItem).fallbackIcon == "music.note")
    }

    @Test func testRemoteServerIcons() {
        #expect(makeSource(kind: .subsonic).fallbackIcon == "server.rack")
        #expect(makeSource(kind: .jellyfin).fallbackIcon == "server.rack")
        #expect(makeSource(kind: .emby).fallbackIcon == "server.rack")
        #expect(makeSource(kind: .plex).fallbackIcon == "server.rack")
    }

    @Test func testRemoteStorageIcons() {
        let icon = "externaldrive.connected.to.line.below"
        #expect(makeSource(kind: .webDAV).fallbackIcon == icon)
        #expect(makeSource(kind: .smb).fallbackIcon == icon)
        #expect(makeSource(kind: .dropbox).fallbackIcon == icon)
        #expect(makeSource(kind: .googleDrive).fallbackIcon == icon)
        #expect(makeSource(kind: .oneDrive).fallbackIcon == icon)
        #expect(makeSource(kind: .pCloud).fallbackIcon == icon)
        #expect(makeSource(kind: .box).fallbackIcon == icon)
        #expect(makeSource(kind: .yandexDisk).fallbackIcon == icon)
    }

    @Test func testLocalFilesAndFolderIconsDiffer() {
        let files = makeSource(kind: .local, localIsFolder: false).fallbackIcon
        let folder = makeSource(kind: .local, localIsFolder: true).fallbackIcon
        let collection = makeSource(kind: .iaCollection).fallbackIcon
        #expect(files != folder)
        #expect(files != collection)
        #expect(folder != collection)
    }
}
