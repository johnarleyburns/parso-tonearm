#if !os(watchOS)
import XCTest
import Foundation
import ParsoAudioStreaming
@testable import TonearmCore

final class HTTPRangeAACSourceTests: XCTestCase {
    final class RangeProtocol: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var response: ((URLRequest) -> (Int, Data, [String: String]))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.requests.append(request) }
            guard let result = Self.lock.withLock({ Self.response?(request) }), let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            let response = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: "HTTP/1.1",
                                           headerFields: result.2)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func tearDown() {
        RangeProtocol.lock.withLock { RangeProtocol.requests = []; RangeProtocol.response = nil }
        super.tearDown()
    }

    func testVerifiedRangeIsCachedAndNotFetchedTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let session = URLSession(configuration: configuration)
        let payload = Data([1, 2, 3, 4])
        RangeProtocol.lock.withLock {
            RangeProtocol.response = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-7")
                return (206, payload, ["Content-Range": "bytes 4-7/12"])
            }
        }
        let cache = SparseCacheStore(evictableRoot: root)
        let source = HTTPRangeAACSource(descriptor: .init(assetID: "asset", url: URL(string: "https://example.invalid/aac")!,
                                                           headers: [:], expectedLength: 12), cache: cache, session: session)
        let file = try await source.require(4..<8, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(try Data(contentsOf: file).subdata(in: 4..<8), payload)
        _ = try await source.require(4..<8, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(RangeProtocol.lock.withLock { RangeProtocol.requests.count }, 1)
    }

    func testExpiredLocatorRefreshesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let session = URLSession(configuration: configuration)
        RangeProtocol.lock.withLock {
            RangeProtocol.response = { request in
                if request.url?.host == "expired.invalid" { return (403, Data(), [:]) }
                return (206, Data([9, 9]), ["Content-Range": "bytes 0-1/2"])
            }
        }
        let cache = SparseCacheStore(evictableRoot: root)
        let source = HTTPRangeAACSource(descriptor: .init(assetID: "asset", url: URL(string: "https://expired.invalid/aac")!,
                                                           headers: [:], expectedLength: 2), cache: cache,
                                         refresh: { .init(assetID: "asset", url: URL(string: "https://fresh.invalid/aac")!,
                                                          headers: [:], expectedLength: 2) }, session: session)
        _ = try await source.require(0..<2, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(RangeProtocol.lock.withLock { RangeProtocol.requests.map { $0.url?.host } }, ["expired.invalid", "fresh.invalid"])
    }
}
#endif
