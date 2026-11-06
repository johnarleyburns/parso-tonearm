import XCTest
@testable import TonearmCore

private final class JamendoStubProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var body = ""
    /// Consumed in order, one per request, for tests that need a DIFFERENT response each call
    /// (e.g. the empty-then-non-empty retry sequence) — falls back to repeating the last entry
    /// (or `body`, if this is empty) once exhausted.
    nonisolated(unsafe) static var bodySequence: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = Self.requests.count
        Self.requests.append(request)
        let responseBody: String
        if !Self.bodySequence.isEmpty {
            responseBody = Self.bodySequence[min(index, Self.bodySequence.count - 1)]
        } else {
            responseBody = Self.body
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func trackJSON(_ id: String) -> String {
    #"{"id":"\#(id)","name":"T\#(id)","duration":100,"audio":"https://example.test/\#(id).mp3"}"#
}

private func envelope(_ ids: [String]) -> String {
    #"{"headers":{"status":"success","code":0,"error_message":""},"results":[\#(ids.map(trackJSON).joined(separator: ","))]}"#
}

@MainActor
final class JamendoAPITests: XCTestCase {
    private func makeAPI() -> JamendoAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JamendoStubProtocol.self]
        JamendoStubProtocol.requests = []
        JamendoStubProtocol.bodySequence = []
        return JamendoAPI(clientID: "cid", session: URLSession(configuration: config))
    }

    private func rawQuery() throws -> String {
        let url = try XCTUnwrap(JamendoStubProtocol.requests.last?.url)
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
    }

    func testMultipleIDsUsePercentEncodedPlus() async throws {
        JamendoStubProtocol.body = envelope(["1884163"])
        _ = try await makeAPI().tracks(ids: ["1884163", "1876521", "1892244"])
        let query = try rawQuery()
        XCTAssertTrue(query.contains("id=1884163%2B1876521%2B1892244"), query)
        XCTAssertFalse(query.contains("id=1884163+1876521+1892244"), query)
        XCTAssertFalse(query.contains("%20"), query)
    }

    func testSingleIDHasNoSeparator() async throws {
        JamendoStubProtocol.body = envelope(["1892244"])
        _ = try await makeAPI().tracks(ids: ["1892244"])
        let query = try rawQuery()
        XCTAssertTrue(query.contains("id=1892244&"), query)
        XCTAssertFalse(query.contains("%2B"), query)
        XCTAssertFalse(query.contains("+"), query)
    }

    func testEmptyIDsMakeNoRequest() async throws {
        let result = try await makeAPI().tracks(ids: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(JamendoStubProtocol.requests.isEmpty)
    }

    func testOtherQueryParametersArePreserved() async throws {
        // A non-empty, matching result — an empty one would now (correctly) trigger the
        // empty-lookup retry below and just slow this test down for no reason.
        JamendoStubProtocol.body = envelope(["1"])
        _ = try await makeAPI().tracks(ids: ["1", "2"])
        let query = try rawQuery()
        for part in ["client_id=cid", "format=json", "limit=2", "include=musicinfo",
                     "audioformat=mp32", "audiodlformat=mp32"] {
            XCTAssertTrue(query.contains(part), "\(part) missing from \(query)")
        }
    }

    func testResponseDecodesInServerOrder() async throws {
        let ids = ["10", "11", "12", "13", "14"]
        // Only three of the requested tracks come back, in reverse order.
        let available = [ids[4], ids[2], ids[0]]
        JamendoStubProtocol.body = envelope(available)
        let decoded = try await makeAPI().tracks(ids: ids)
        XCTAssertEqual(decoded.map(\.id), available)
        XCTAssertEqual(decoded.first?.audio, "https://example.test/\(ids[4]).mp3")
    }

    // MARK: - tracks(ids:) empty-lookup retry

    /// Real report: "Find -> Genre" Jamendo tracks wouldn't play at all. Root cause: the
    /// play-time locator refresh (`JamendoLocatorRefresh`) calls `tracks(ids: [trackID])` with no
    /// retry of its own, and treats any failure as immediately fatal — so a single instance of
    /// this same confirmed-live upstream flake (a well-formed `success` envelope with zero
    /// matching rows) permanently failed that one play attempt.
    func testEmptyIDLookupRetriesBeforeSucceeding() async throws {
        JamendoStubProtocol.bodySequence = [envelope([]), envelope(["42"])]
        let tracks = try await makeAPI().tracks(ids: ["42"])
        XCTAssertEqual(tracks.map(\.id), ["42"])
        XCTAssertEqual(JamendoStubProtocol.requests.count, 2, "initial attempt + 1 retry")
    }

    /// A genuinely gone/invalid id must still resolve to an empty array (the caller decides what
    /// that means) rather than retrying forever.
    func testEmptyIDLookupGivesUpAfterExhaustingRetries() async throws {
        JamendoStubProtocol.body = envelope([])
        let tracks = try await makeAPI().tracks(ids: ["999999"])
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertEqual(JamendoStubProtocol.requests.count, 3, "initial attempt + 2 retries, then stop")
    }

    /// A partial match (some requested ids came back, some didn't) is not retried — only a
    /// complete miss is treated as the transient-flake case.
    func testPartiallyMatchingIDLookupIsNotRetried() async throws {
        JamendoStubProtocol.body = envelope(["1"])
        let tracks = try await makeAPI().tracks(ids: ["1", "2"])
        XCTAssertEqual(tracks.map(\.id), ["1"])
        XCTAssertEqual(JamendoStubProtocol.requests.count, 1)
    }

    // MARK: - tags(tag:offset:limit:) empty-first-page retry

    /// Real report, confirmed live against the real API: an identical `tags=dance` request
    /// returned a real, non-empty page on one attempt and then zero on the next TWO consecutive
    /// attempts moments later — a single retry isn't always enough.
    func testEmptyFirstPageRetriesUpToTwiceBeforeSucceeding() async throws {
        JamendoStubProtocol.bodySequence = [envelope([]), envelope([]), envelope(["1"])]
        let page = try await makeAPI().tracks(tag: "dance", offset: 0, limit: 10)
        XCTAssertEqual(page.tracks.map(\.id), ["1"])
        XCTAssertEqual(JamendoStubProtocol.requests.count, 3, "initial attempt + 2 retries")
    }

    /// A tag that's genuinely empty (not just transiently flaky) must still resolve to an empty
    /// page rather than throwing or retrying forever — exactly 3 attempts, then give up quietly.
    func testEmptyFirstPageGivesUpAfterExhaustingRetries() async throws {
        JamendoStubProtocol.body = envelope([])
        let page = try await makeAPI().tracks(tag: "nonexistent-tag", offset: 0, limit: 10)
        XCTAssertTrue(page.tracks.isEmpty)
        XCTAssertEqual(JamendoStubProtocol.requests.count, 3, "initial attempt + 2 retries, then stop")
    }

    /// Only the first page gets the retry treatment — a real end of a non-empty list (offset > 0)
    /// must never be mistaken for the transient-empty-first-page flake.
    func testEmptyLaterPageIsNeverRetried() async throws {
        JamendoStubProtocol.body = envelope([])
        let page = try await makeAPI().tracks(tag: "dance", offset: 50, limit: 10)
        XCTAssertTrue(page.tracks.isEmpty)
        XCTAssertEqual(JamendoStubProtocol.requests.count, 1, "no retry past the first page")
    }
}
