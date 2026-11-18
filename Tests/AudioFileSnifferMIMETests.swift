import Foundation
import Testing
@testable import TonearmCore

/// Extensionless Mood/Jamendo cache blobs need a format hint derived from the bytes themselves.
@Suite struct AudioFileSnifferMIMETests {
    @Test func testMIMEFromMagicBytes() {
        #expect(AudioFileSniffer.mimeType(prefix: Data([0x49, 0x44, 0x33, 0x04, 0, 0])) == "audio/mpeg")
        #expect(AudioFileSniffer.mimeType(prefix: Data([0xFF, 0xFB, 0x90, 0x00])) == "audio/mpeg")
        #expect(AudioFileSniffer.mimeType(prefix: Data("fLaC0000".utf8)) == "audio/flac")
        #expect(AudioFileSniffer.mimeType(prefix: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70])) == "audio/mp4")
    }

    @Test func testErrorBodyHasNoMIMEAndIsNotAudio() {
        let body = Data("{\"error\":1}".utf8)
        #expect(AudioFileSniffer.mimeType(prefix: body) == nil)
        #expect(!AudioFileSniffer.looksLikeAudio(prefix: body))
    }

    @Test func testPlayableCompleteBlobURLIsNilWhenNothingCached() {
        let url = URL(string: "https://example.invalid/never-cached-\(UUID().uuidString)?trackid=1")!
        #expect(AudioCache.playableCompleteBlobURL(for: url) == nil)
    }
}
