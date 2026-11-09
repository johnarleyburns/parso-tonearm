import XCTest

/// `AppState` lives under `Sources/App/`, which `Package.swift` excludes from the `TonearmCore`
/// SwiftPM target entirely — `swift test` cannot import or construct it. Source-inspection is
/// the established pattern for pinning `AppState`-level behavior here (see
/// `FavoriteAndHistoryGuardOrderingTests` in `Tests/FavoriteAndHistoryTransientTrackTests.swift`).
///
/// `RemoteTrackRowFactory.row` already sets `Asset.remoteContentType` on an in-memory,
/// just-browsed row (the one place Google Drive's `mimeType` survives, since its stream URL is
/// an extensionless `?alt=media` link). Real report: that hint was lost the moment the row got
/// persisted through `playRemote`/`toggleFavorite`/custom-artwork/watch-prep — `performPersistRemoteTrack`
/// built its own synthetic `RemoteNode` to hand to `RemotePlaylistIngest.persist` and never
/// carried `asset.remoteContentType` onto it, so the saved row lost the hint even though the
/// in-memory one it came from had it. The track then played fine once (streamed, in memory) but
/// failed the next time (cached-file replay, no format hint).
final class PersistRemoteTrackContentTypeTests: XCTestCase {
    func testPerformPersistRemoteTrackCarriesContentTypeOntoTheSyntheticNode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/App/AppState+Downloads.swift"),
            encoding: .utf8)
        let function = try XCTUnwrap(source.range(of: "private func performPersistRemoteTrack("))
        let body = source[function.upperBound...]
        let closingBrace = try XCTUnwrap(body.range(of: "\n    }\n"))
        let functionBody = body[..<closingBrace.lowerBound]
        let nodeConstruction = try XCTUnwrap(functionBody.range(of: "let node = RemoteNode("))
        let nodeCallEnd = try XCTUnwrap(functionBody[nodeConstruction.lowerBound...].range(of: ")\n"))
        let nodeCall = functionBody[nodeConstruction.lowerBound..<nodeCallEnd.upperBound]
        XCTAssertTrue(nodeCall.contains("contentType: asset.remoteContentType"),
            "the synthetic RemoteNode performPersistRemoteTrack hands to RemotePlaylistIngest.persist " +
            "must carry the in-memory row's content-type hint through, or it's lost the moment the row is saved")
    }
}
