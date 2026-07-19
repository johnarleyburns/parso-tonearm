import XCTest
@testable import TonearmCore

final class RemoteStreamingResponsePolicyTests: XCTestCase {
    func testProbeAcceptsRangeResponse() {
        let result = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 206,
            contentRange: "bytes 0-0/4096",
            expectedContentLength: 1
        )

        XCTAssertEqual(result, .ranged(totalBytes: 4096))
        XCTAssertEqual(result?.supportsByteRanges, true)
    }

    func testProbeAcceptsValidFullBodyResponse() {
        let result = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: 4096
        )

        XCTAssertEqual(result, .fullBody(totalBytes: 4096))
        XCTAssertEqual(result?.supportsByteRanges, false)
    }

    func testProbeRejectsFullBodyWithoutLength() {
        let result = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: -1
        )

        XCTAssertNil(result)
    }

    func testDataResponseAcceptsRangeAtCursor() {
        let response = RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 206,
            contentRange: "bytes 1024-2047/4096",
            expectedContentLength: 1024,
            cursor: 1024,
            knownTotalBytes: 4096
        )

        XCTAssertEqual(response, .ranged(start: 1024))
    }

    func testDataResponseAcceptsFullBodyAtStartOnly() {
        let response = RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: 4096,
            cursor: 0,
            knownTotalBytes: 4096
        )

        XCTAssertEqual(response, .fullBody(totalBytes: 4096))
        XCTAssertNil(RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: 4096,
            cursor: 1024,
            knownTotalBytes: 4096
        ))
    }
}
