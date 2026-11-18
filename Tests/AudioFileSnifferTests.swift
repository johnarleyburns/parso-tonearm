import Foundation
import Testing
@testable import TonearmCore

@Suite struct AudioFileSnifferTests {
    private func bytes(_ values: [UInt8]) -> Data { Data(values) }

    @Test func testRecognizesID3TaggedMP3() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: bytes([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0])))
    }

    @Test func testRecognizesBareMPEGFrameSync() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: bytes([0xFF, 0xFB, 0x90, 0x64, 0, 0, 0, 0])))
    }

    @Test func testRecognizesFLAC() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: Data("fLaC".utf8) + Data(repeating: 0, count: 4)))
    }

    @Test func testRecognizesOggVorbisOrOpus() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: Data("OggS".utf8) + Data(repeating: 0, count: 4)))
    }

    @Test func testRecognizesWAV() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: Data("RIFF".utf8) + Data("WAVE".utf8)))
    }

    @Test func testRecognizesAIFF() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: Data("FORM".utf8) + Data("AIFF".utf8)))
    }

    @Test func testRecognizesMP4ContainerByFtypBox() {
        let prefix = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)
        #expect(AudioFileSniffer.looksLikeAudio(prefix: prefix))
    }

    /// Real report this is for: an expired Dropbox temp link / revoked token response body
    /// (a JSON error, or an HTML error page from an edge/proxy) got cached and durably adopted
    /// as if it were the audio file.
    @Test func testRejectsJSONErrorBody() {
        let body = #"{"error":"expired_access_token"}"#
        #expect(!AudioFileSniffer.looksLikeAudio(prefix: Data(body.utf8)))
    }

    @Test func testRejectsJSONArrayBody() {
        #expect(!AudioFileSniffer.looksLikeAudio(prefix: Data(#"[{"error":"rate_limited"}]"#.utf8)))
    }

    @Test func testRejectsHTMLErrorPage() {
        #expect(!AudioFileSniffer.looksLikeAudio(prefix: Data("<html><body>403</body></html>".utf8)))
    }

    @Test func testTooShortAPrefixIsInconclusiveNotFlagged() {
        #expect(AudioFileSniffer.looksLikeAudio(prefix: Data([0x7B])))
    }
}
