import XCTest
import TonearmWatchProtocol
@testable import TonearmWatchCore

/// Phase 10b — privacy-safe structured diagnostics and the in-app export (§12).
final class WatchDiagnosticsTests: XCTestCase {

    // MARK: - Bounded ring

    func testRingDropsOldestPastCapacity() {
        var log = WatchDiagnosticsLog(capacity: 3)
        for i in 0..<5 {
            log.record(WatchDiagnosticEvent(category: .request, stateCode: "n\(i)",
                                            timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        XCTAssertEqual(log.snapshot().map(\.stateCode), ["n2", "n3", "n4"])
        XCTAssertLessThanOrEqual(log.snapshot().count, 3)
    }

    func testRecorderPreservesOrderAndStampsClock() async {
        let fixed = Date(timeIntervalSince1970: 5)
        let recorder = WatchDiagnosticsRecorder(capacity: 10, clock: { fixed })
        await recorder.record(.activation, "activated")
        await recorder.record(.disconnectDuration, "reconnected", durationMillis: 5000)

        let events = await recorder.events()
        XCTAssertEqual(events.map(\.stateCode), ["activated", "reconnected"])
        XCTAssertEqual(events[1].timestamp, fixed)
        XCTAssertEqual(events[1].durationMillis, 5000)
    }

    func testRemoveAllClearsButKeepsCapacity() async {
        let recorder = WatchDiagnosticsRecorder(capacity: 4)
        await recorder.record(.routeEvent, "routeLost")
        await recorder.removeAll()
        let events = await recorder.events()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Hashing

    func testSameIDAndSaltHashEqual_differentSaltDiffers() {
        let salt = Data([1, 2, 3, 4])
        let a = WatchDiagnosticsExporter.hash("req-42", salt: salt)
        let b = WatchDiagnosticsExporter.hash("req-42", salt: salt)
        let c = WatchDiagnosticsExporter.hash("req-42", salt: Data([9, 9, 9, 9]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 16)
    }

    // MARK: - Export redaction

    func testExportHashesCorrelationIDAndOmitsRawValue() throws {
        let secret = "session-topsecret-bearer-abc123"
        let events = [
            WatchDiagnosticEvent(category: .request, stateCode: "timeout",
                                 timestamp: Date(timeIntervalSince1970: 100),
                                 correlationID: secret, durationMillis: 4200),
            WatchDiagnosticEvent(category: .transferState, stateCode: "sending",
                                 timestamp: Date(timeIntervalSince1970: 101),
                                 byteCount: 1_234_567, count: 12)
        ]
        let export = WatchDiagnosticsExporter.export(events: events, appVersion: "9.9.9",
                                                     generatedAt: Date(timeIntervalSince1970: 200),
                                                     salt: Data([7, 7, 7, 7]))
        XCTAssertEqual(export.eventCount, 2)
        XCTAssertEqual(export.protocolVersion, WatchProtocolVersion.current)

        let json = try WatchDiagnosticsExporter.encode(export)
        let text = String(decoding: json, as: UTF8.self)

        XCTAssertFalse(text.contains(secret), "raw correlation id must never be emitted")
        XCTAssertFalse(text.contains("topsecret"))
        XCTAssertTrue(text.contains(WatchDiagnosticsExporter.hash(secret, salt: Data([7, 7, 7, 7]))))
        XCTAssertTrue(text.contains("\"byteCount\" : 1234567"))
        XCTAssertNil(export.entries[1].correlationHash)
    }

    func testExportRoundTrips() throws {
        let events = [WatchDiagnosticEvent(category: .storeRecovery, stateCode: "rebuilt",
                                           timestamp: Date(timeIntervalSince1970: 42), count: 3)]
        let export = WatchDiagnosticsExporter.export(events: events, appVersion: "1.0",
                                                     generatedAt: Date(timeIntervalSince1970: 50),
                                                     salt: Data([0]))
        let decoded = try JSONDecoder.iso8601().decode(
            WatchDiagnosticsExport.self,
            from: try WatchDiagnosticsExporter.encode(export))
        XCTAssertEqual(decoded, export)
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
