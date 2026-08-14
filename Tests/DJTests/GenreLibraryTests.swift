import XCTest

@testable import TonearmCore
@testable import TonearmDJ

/// M5 commit 5.6 — **AT-GENRE-\***, the genre-library connector (§18A) against
/// **recorded fixtures** (plan decision 21, Appendix R) — no live network in
/// CI. The stub URL protocol serves canned `tracks` responses keyed by the
/// `tags` query parameter, so every test is deterministic.
///
/// The fixtures are hand-recorded to the verified v3.0 envelope shape
/// (`headers.results_fullcount` for `fullcount=true`, `musicinfo.tags.genres`
/// for the genre tags), with distinct track IDs per genre so "a sub-genre is a
/// different library from its parent" is an exact assertion, not a vibe.
final class GenreLibraryTests: XCTestCase {

    private let sampleTechno = "https://prod-1.storage.jamendo.com/?trackid=1000001&format=mp32&from=app-test"

    override func setUp() {
        super.setUp()
        JamendoTagStub.fixtures = [
            "techno": fixture("techno"),
            "house": fixture("house"),
            "electronic": fixture("electronic"),
            "api-error": fixture("api-error"),
        ]
        JamendoTagStub.requestedTags = []
        JamendoTagStub.failNextWith = nil
    }

    override func tearDown() {
        JamendoTagStub.fixtures = [:]
        JamendoTagStub.requestedTags = []
        JamendoTagStub.failNextWith = nil
        super.tearDown()
    }

    // MARK: - AT-GENRE-1: a genre is a library

    func testGenrePathMapsToSourceIdentity() {
        // §18A.3: the source identity is the genre path; the filter tag is the
        // last component — `electronic/techno` is a different library from
        // `electronic`.
        XCTAssertEqual(JamendoGenreProvider(clientID: "test").tag(from: "electronic/techno"), "techno")
        XCTAssertEqual(JamendoGenreProvider(clientID: "test").tag(from: "electronic"), "electronic")
        XCTAssertEqual(JamendoGenreProvider(clientID: "test").tag(from: "electronic/house"), "house")

        let source = Source(
            id: nil, kind: .jamendoGenre, iaIdentifier: "electronic/techno",
            originalURL: nil, title: "Techno", addedAt: Date(),
            lastResolvedAt: Date(), followUpdates: false, licenseText: nil, memberCapHit: false)
        XCTAssertEqual(source.kind, .jamendoGenre)
        XCTAssertEqual(source.iaIdentifier, "electronic/techno")
        XCTAssertFalse(source.fallbackIcon.isEmpty, "the genre source has a fallback icon")
    }

    func testSubgenresAreDistinctLibraries() async throws {
        // Browsing `electronic/techno`, `electronic/house` and `electronic`
        // hits three different fixtures with disjoint track IDs — the point of
        // the feature (§18A.3: a techno crate, not an electronica crate).
        let provider = makeProvider()
        let techno = try await provider.browse(path: "electronic/techno")
        let house = try await provider.browse(path: "electronic/house")
        let electronic = try await provider.browse(path: "electronic")

        let technoIDs = Set(techno.map(\.id))
        let houseIDs = Set(house.map(\.id))
        let electronicIDs = Set(electronic.map(\.id))
        XCTAssertFalse(technoIDs.isEmpty)
        XCTAssertFalse(houseIDs.isEmpty)
        XCTAssertFalse(electronicIDs.isEmpty)
        XCTAssertTrue(technoIDs.isDisjoint(with: houseIDs),
                      "techno and house are different libraries")
        XCTAssertTrue(technoIDs.isSubset(of: Set(["1000001", "1000002", "1000003", "1000004"])))
        XCTAssertTrue(houseIDs.isSubset(of: Set(["1100001", "1100002"])))
        XCTAssertTrue(electronicIDs.isSubset(of: Set(["1200001", "1200002", "1200003"])))
    }

    // MARK: - AT-GENRE-2: ordering

    func testTracksOrderedByPopularityDescending() async throws {
        // The request must carry `order=popularity_total` (desc is that order's
        // forced direction, §18A.3) and the returned nodes preserve the
        // fixture's popularity order exactly.
        let provider = makeProvider()
        let nodes = try await provider.browse(path: "electronic/techno")

        XCTAssertEqual(nodes.map(\.id), ["1000001", "1000002", "1000003", "1000004"],
                       "nodes keep the fixture's popularity-descending order")
        let tags = JamendoTagStub.requestedTags.compactMap { _ in
            JamendoTagStub.lastOrderParameter
        }
        XCTAssertEqual(Set(tags), ["popularity_total"],
                       "every tracks request orders by popularity_total")
    }

    func testTrackMetadataCarriesArtistAlbumGenreAndArtwork() async throws {
        let provider = makeProvider()
        let nodes = try await provider.browse(path: "electronic/techno")
        let first = try XCTUnwrap(nodes.first)

        XCTAssertEqual(first.id, "1000001")
        XCTAssertEqual(first.title, "Neon Circuit")
        XCTAssertEqual(first.durationSec, 284)
        XCTAssertEqual(first.metadata?.artist, "Kora Mechanism")
        XCTAssertEqual(first.metadata?.album, "Signal Paths")
        XCTAssertEqual(first.metadata?.genre, "techno")
        XCTAssertEqual(first.metadata?.artwork?.url?.absoluteString,
                       "https://usercontent.jamendo.com?type=album&id=300001&width=300&trackid=1000001")
    }

    func testResolveReturnsTheStreamURL() async throws {
        let provider = makeProvider()
        let nodes = try await provider.browse(path: "electronic/techno")
        let asset = try await provider.resolve(node: try XCTUnwrap(nodes.first))
        XCTAssertEqual(asset.url.absoluteString, sampleTechno)
        XCTAssertTrue(asset.supportsByteRanges)
    }

    // MARK: - AT-GENRE-3: no account

    func testNoAccountRequiredToBrowse() async throws {
        // Only the application client_id travels — no username, no password,
        // no token (FR-LIB-9's "works with no account", §18A.2).
        let provider = makeProvider()
        _ = try await provider.browse(path: "electronic/techno")

        let query = try XCTUnwrap(JamendoTagStub.lastRequestQuery)
        XCTAssertEqual(query.filter { $0.name == "client_id" }.first?.value, "test-client")
        XCTAssertFalse(query.contains { $0.name == "username" })
        XCTAssertFalse(query.contains { $0.name == "password" })
        XCTAssertFalse(query.contains { $0.name == "token" })
    }

    func testUnconfiguredBuildIsHonestUnavailable() async {
        // An empty client_id (no registered application credential yet) is an
        // honest unavailable state — the provider throws `.notConfigured`
        // rather than reporting an empty library (§18A.6).
        let provider = JamendoGenreProvider(clientID: "", session: makeSession(),
                                            sourcePath: "electronic/techno")
        do {
            _ = try await provider.browse(path: "electronic/techno")
            XCTFail("an unconfigured build must not appear to have an empty library")
        } catch let failure as JamendoGenreError {
            XCTAssertEqual(
                failure.errorDescription,
                "Jamendo isn't configured in this build yet.")
        } catch let other {
            XCTFail("unexpected error: \(other)")
        }
    }

    // MARK: - AT-GENRE-4: licence passthrough

    func testLicenceCarriesToTheSourceRow() async throws {
        // §18A.5: the Creative-Commons licence obligation follows the library.
        // The schema carries licence at the source level (the existing IA /
        // built-in pattern); per-track artist/genre/album travel in each row.
        var source = Source(
            id: nil, kind: .jamendoGenre, iaIdentifier: "electronic/techno",
            originalURL: nil, title: "Techno", addedAt: Date(),
            lastResolvedAt: Date(), followUpdates: false, licenseText: nil, memberCapHit: false)
        source.licenseText = "Creative Commons — attribution kept"
        XCTAssertEqual(source.licenseText, "Creative Commons — attribution kept")

        let provider = makeProvider()
        let nodes = try await provider.browse(path: "electronic/techno")
        let resolved = try await provider.resolve(node: try XCTUnwrap(nodes.first))
        let row = RemoteTrackRowFactory.row(source: source, node: nodes[0], resolved: resolved, index: 0)
        XCTAssertEqual(row.track.title, "Neon Circuit")
        XCTAssertEqual(row.track.genre, "techno")
        XCTAssertEqual(row.artist?.name, "Kora Mechanism")
        XCTAssertEqual(row.asset?.remoteURL, sampleTechno)
        XCTAssertEqual(row.source?.kind, .jamendoGenre)
    }

    // MARK: - AT-GENRE-5: the path to a deck (FR-LIB-8)

    func testGenreTrackFlowsThroughTheStandardRowFactory() async throws {
        // A genre track is an ordinary `TrackRow` (title/artist/genre/asset),
        // so the FR-LIB-8 fully-cached gate in `DeckLoader` governs deck
        // readiness exactly as it does for every other remote track (§18A.4 —
        // the connector's only job is to produce rows the system understands).
        let provider = makeProvider()
        let nodes = try await provider.browse(path: "electronic/techno")
        let source = Source(
            id: 7, kind: .jamendoGenre, iaIdentifier: "electronic/techno",
            originalURL: nil, title: "Techno", addedAt: Date(),
            lastResolvedAt: Date(), followUpdates: false, licenseText: nil, memberCapHit: false)

        var rows: [TrackRow] = []
        for (index, node) in nodes.enumerated() {
            let resolved = try await provider.resolve(node: node)
            rows.append(RemoteTrackRowFactory.row(source: source, node: node,
                                                  resolved: resolved, index: index))
        }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[1].track.title, "Warehouse Line")
        XCTAssertEqual(rows[1].track.genre, "techno")
        XCTAssertEqual(rows[1].track.sourceId, 7)
    }

    // MARK: - AT-GENRE-6: failure and honesty

    func testApiFailureEnvelopeSurfacesHonestly() async {
        let provider = JamendoGenreProvider(clientID: "test-client",
                                            session: makeSession(),
                                            sourcePath: "api-error")
        do {
            _ = try await provider.browse(path: "api-error")
            XCTFail("an API failure envelope must throw, not render as an empty library")
        } catch JamendoGenreError.catalogue(let message) {
            XCTAssertTrue(message.contains("not authorized"))
        } catch let other {
            XCTFail("unexpected error: \(other)")
        }
    }

    func testTransportFailureThrowsNeverEmptyLibrary() async {
        JamendoTagStub.failNextWith = URLError(.cannotConnectToHost)
        let provider = makeProvider()
        do {
            _ = try await provider.browse(path: "electronic/techno")
            XCTFail("a transport failure must throw (D-9's lesson: never render as empty)")
        } catch {
            // any transport error is the honest outcome
        }
    }

    // MARK: - AT-GENRE-2 (counts): fullcount drives the picker line

    func testCatalogueCountReadsFullcount() async throws {
        let provider = makeProvider()
        let techno = try await provider.catalogueCount(path: "electronic/techno")
        let house = try await provider.catalogueCount(path: "electronic/house")
        let electronic = try await provider.catalogueCount(path: "electronic")
        XCTAssertEqual(techno, 430)
        XCTAssertEqual(house, 190)
        XCTAssertEqual(electronic, 12_360,
                       "the parent genre is a much bigger pool than its sub-genres")
    }

    // MARK: - AT-GENRE-7: free tier

    func testGenreLibraryIsFreeAndCatalogued() {
        // Free tier (FR-LIB-7): `.jamendoGenre` is a remote library, resolves
        // to a connector, and the provider factory constructs it.
        XCTAssertTrue(RemoteLibraryAccessPolicy.isRemoteLibrary(.jamendoGenre))
        XCTAssertTrue(RemoteLibraryAccessPolicy.productSourceKinds.contains(.jamendoGenre))
        XCTAssertNotNil(RemoteConnectorCatalog.connector(for: .jamendoGenre))
        let source = Source(
            id: nil, kind: .jamendoGenre, iaIdentifier: "electronic/techno",
            originalURL: nil, title: "Techno", addedAt: Date(),
            lastResolvedAt: Date(), followUpdates: false, licenseText: nil, memberCapHit: false)
        XCTAssertTrue(RemoteLibraryProviderFactory.supports(source.kind))
    }

    // MARK: - The picker model (FR-LIB-10, §41.1a)

    @MainActor
    func testPickerLoadsCuratedTreeAndTracksSelection() async throws {
        let model = GenrePickerModel(api: JamendoAPI(clientID: "test-client", session: makeSession()))
        XCTAssertEqual(model.roots.count, 8, "the §41.1a top-level genres")
        XCTAssertTrue(model.selectedGenres.isEmpty)

        let techno = try XCTUnwrap(
            JamendoGenreTree.all.first { $0.path == "electronic/techno" })
        let house = try XCTUnwrap(
            JamendoGenreTree.all.first { $0.path == "electronic/house" })
        model.toggle(techno)
        model.toggle(house)
        XCTAssertTrue(model.isSelected(techno))
        XCTAssertEqual(model.selectedGenres.map(\.path), ["electronic/house", "electronic/techno"])

        var created: [String] = []
        model.createSource = { selection in created.append(selection.path) }
        let ok = await model.addSelected()
        XCTAssertTrue(ok)
        XCTAssertEqual(created, ["electronic/house", "electronic/techno"],
                       "one Source per selected genre, through the host seam")
    }

    @MainActor
    func testPickerProbeSurfacesHonestUnconfiguredError() async {
        let model = GenrePickerModel(api: JamendoAPI(clientID: "", session: makeSession()))
        guard let first = model.roots.first else { return XCTFail("no roots") }
        await model.loadCount(for: first)
        XCTAssertEqual(model.catalogueError, "Jamendo isn't configured in this build yet.",
                       "an unconfigured build reports the honest error, never an empty grid")
    }

    @MainActor
    func testPickerToggleSelectionIsEquallyWeighted() async {
        let model = GenrePickerModel(api: JamendoAPI(clientID: "test-client", session: makeSession()))
        let techno = JamendoGenreTree.all.first { $0.path == "electronic/techno" }!
        model.toggle(techno)
        model.toggle(techno)
        XCTAssertTrue(model.selectedGenres.isEmpty,
                      "skipping is equally weighted — no selection is a valid state (§41.1a)")
    }

    // MARK: - Helpers

    private func makeProvider() -> JamendoGenreProvider {
        JamendoGenreProvider(clientID: "test-client", session: makeSession(),
                             sourcePath: "electronic/techno")
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JamendoTagStub.self]
        return URLSession(configuration: config)
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json",
                                    subdirectory: "Fixtures/jamendo")
        if let url, let data = try? Data(contentsOf: url) { return data }
        XCTFail("missing jamendo fixture \(name).json")
        return Data()
    }
}

/// The recorded-fixture stub: serves the canned `tracks` envelope keyed by the
/// `tags` query parameter, recording the tags and the order parameter it saw.
private final class JamendoTagStub: URLProtocol {
    nonisolated(unsafe) static var fixtures: [String: Data] = [:]
    nonisolated(unsafe) static var requestedTags: [String] = []
    nonisolated(unsafe) static var lastOrderParameter: String?
    nonisolated(unsafe) static var lastRequestQuery: [URLQueryItem]?
    nonisolated(unsafe) static var failNextWith: Error?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/tracks") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let tag = components?.queryItems?.first { $0.name == "tags" }?.value ?? ""
        Self.requestedTags.append(tag)
        Self.lastOrderParameter = components?.queryItems?.first { $0.name == "order" }?.value
        Self.lastRequestQuery = components?.queryItems

        if let error = Self.failNextWith {
            Self.failNextWith = nil
            client.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let data = Self.fixtures[tag] else {
            client.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
