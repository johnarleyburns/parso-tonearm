import XCTest
@testable import TonearmCore

/// Extensionless Mood/Jamendo cache blobs need a format hint derived from the bytes themselves.
final class AudioFileSnifferMIMETests: XCTestCase {
    func testMIMEFromMagicBytes() {
        XCTAssertEqual(AudioFileSniffer.mimeType(prefix: Data([0x49, 0x44, 0x33, 0x04, 0, 0])), "audio/mpeg")
        XCTAssertEqual(AudioFileSniffer.mimeType(prefix: Data([0xFF, 0xFB, 0x90, 0x00])), "audio/mpeg")
        XCTAssertEqual(AudioFileSniffer.mimeType(prefix: Data("fLaC0000".utf8)), "audio/flac")
        XCTAssertEqual(AudioFileSniffer.mimeType(prefix: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70])), "audio/mp4")
    }

    func testErrorBodyHasNoMIMEAndIsNotAudio() {
        let body = Data("{\"error\":1}".utf8)
        XCTAssertNil(AudioFileSniffer.mimeType(prefix: body))
        XCTAssertFalse(AudioFileSniffer.looksLikeAudio(prefix: body))
    }

    func testPlayableCompleteBlobURLIsNilWhenNothingCached() {
        let url = URL(string: "https://example.invalid/never-cached-\(UUID().uuidString)?trackid=1")!
        XCTAssertNil(AudioCache.playableCompleteBlobURL(for: url))
    }
}
