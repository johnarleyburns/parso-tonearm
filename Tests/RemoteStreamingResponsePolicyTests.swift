import Testing
@testable import TonearmCore

@Suite struct RemoteStreamingResponsePolicyTests {
    @Test func testProbeAcceptsRangeResponse() {
        let result = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 206,
            contentRange: "bytes 0-0/4096",
            expectedContentLength: 1
        )

        #expect(result == .ranged(totalBytes: 4096))
        #expect(result?.supportsByteRanges == true)
    }

    @Test func testProbeAcceptsValidFullBodyResponse() {
        let result = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: 4096
        )

        #expect(result == .fullBody(totalBytes: 4096))
        #expect(result?.supportsByteRanges == false)
    }

    @Test func testProbeRejectsFullBodyWithoutLength() {
        let result = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: -1
        )

        #expect(result == nil)
    }

    @Test func testDataResponseAcceptsRangeAtCursor() {
        let response = RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 206,
            contentRange: "bytes 1024-2047/4096",
            expectedContentLength: 1024,
            cursor: 1024,
            knownTotalBytes: 4096
        )

        #expect(response == .ranged(start: 1024))
    }

    @Test func testDataResponseAcceptsFullBodyAtStartOnly() {
        let response = RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: 4096,
            cursor: 0,
            knownTotalBytes: 4096
        )

        #expect(response == .fullBody(totalBytes: 4096))
        #expect(RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 200,
            contentRange: nil,
            expectedContentLength: 4096,
            cursor: 1024,
            knownTotalBytes: 4096
        ) == nil)
    }
}
