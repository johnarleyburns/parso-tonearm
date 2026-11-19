#if !os(watchOS)
import Foundation
import Testing
@testable import TonearmCore

/// Regression for the real report: a Google Drive track played fine on first
/// stream but failed on the second, cached-file play, with a toast reporting
/// it could not be played — even though it was 100% cached. Google Drive's
/// download URL (`?alt=media`) and its extensionless cache blob give
/// `AVFoundation` no way to infer the audio format, and (unlike Jamendo)
/// there is no `format=`-style query parameter to fall back on either.
///
/// `AudioPlayer.remoteAudioMIMEType(for:knownContentType:)` fixes this by
/// accepting the provider's own MIME type (threaded from
/// `RemoteNode.contentType` through `Asset.remoteContentType`), which must
/// win over any URL-based guess.
extension SharedProductionSingletonTests {
    @MainActor
    @Suite struct AudioPlayerRemoteMIMETypeTests {
        private let player = AudioPlayer()

        @Test func testKnownContentTypeOverridesURLInference() {
            // No extension and a query-string hint a real provider could give —
            // establishes what inference alone would produce.
            let remote = URL(string: "https://example.com/stream?format=flac")!
            let inferred = player.remoteAudioMIMEType(for: remote)
            #expect(inferred == "audio/flac")

            // A provider-supplied MIME type must win even when it disagrees with
            // the URL-based guess above.
            let withKnownType = player.remoteAudioMIMEType(
                for: remote, knownContentType: "audio/mp4")
            #expect(withKnownType == "audio/mp4")
        }

        @Test func testKnownContentTypeWinsForAnExtensionlessURLWithNoHints() {
            // Google Drive's real shape: no extension, no recognizable query
            // parameter — without the fix this returns nil and AVFoundation is
            // left to guess.
            let remote = URL(string: "https://www.googleapis.com/drive/v3/files/abc123?alt=media")!
            #expect(player.remoteAudioMIMEType(for: remote) == nil)

            #expect(
                player.remoteAudioMIMEType(for: remote, knownContentType: "audio/mpeg") ==
                "audio/mpeg")
        }

        @Test func testEmptyKnownContentTypeIsIgnored() {
            let remote = URL(string: "https://example.com/stream?format=flac")!
            #expect(
                player.remoteAudioMIMEType(for: remote, knownContentType: "") ==
                "audio/flac",
                "an empty provider-reported MIME type must fall back to inference, not win as a blank hint")
        }
    }
}
#endif
