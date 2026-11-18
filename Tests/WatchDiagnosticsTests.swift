import Foundation
import Testing
import TonearmWatchProtocol
@testable import TonearmWatchCore

/// Phase 10b — privacy-safe structured diagnostics and the in-app export (§12).
@Suite struct WatchDiagnosticsTests {

    @Test func testNativeReceiptAndSnapshotRequireNoBackgroundTask() {
        let fixed = Date(timeIntervalSince1970: 42)
        let recorder = WatchDiagnosticsRecorder(capacity: 2, clock: { fixed })
        recorder.recordImmediately(.installResult, "nativeAudioFileReceived")
        recorder.recordImmediately(.installResult, "audioSavedAwaitingWorker")
        #expect(recorder.snapshot().map(\.stateCode) ==
                       ["nativeAudioFileReceived", "audioSavedAwaitingWorker"])
        #expect(recorder.snapshot().last?.timestamp == fixed)
    }

    @Test func testConcurrentImmediateReceiptsRemainBounded() {
        let recorder = WatchDiagnosticsRecorder(capacity: 32)
        DispatchQueue.concurrentPerform(iterations: 512) { i in
            recorder.recordImmediately(.request, "event\(i)")
            #expect(recorder.snapshot().count <= 32)
        }
        #expect(recorder.snapshot().count == 32)
    }

    @Test func testProductionDiagnosticsReadsMemoryWithoutAwaitingSyncWorkers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchDiagnosticsView.swift"), encoding: .utf8)
        #expect(view.contains("diagnostics.snapshot()"))
        #expect(!view.contains("await "))
        let phone = try String(contentsOf: root.appendingPathComponent("Sources/Features/Settings/WatchSettingsView.swift"), encoding: .utf8)
        #expect(!phone.contains("Total watch storage used"))
    }

    // MARK: - Bounded ring

    @Test func testRingDropsOldestPastCapacity() {
        var log = WatchDiagnosticsLog(capacity: 3)
        for i in 0..<5 {
            log.record(WatchDiagnosticEvent(category: .request, stateCode: "n\(i)",
                                            timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        #expect(log.snapshot().map(\.stateCode) == ["n2", "n3", "n4"])
        #expect(log.snapshot().count <= 3)
    }

    @Test func testRecorderPreservesOrderAndStampsClock() async {
        let fixed = Date(timeIntervalSince1970: 5)
        let recorder = WatchDiagnosticsRecorder(capacity: 10, clock: { fixed })
        await recorder.record(.activation, "activated")
        await recorder.record(.disconnectDuration, "reconnected", durationMillis: 5000)

        let events = await recorder.events()
        #expect(events.map(\.stateCode) == ["activated", "reconnected"])
        #expect(events[1].timestamp == fixed)
        #expect(events[1].durationMillis == 5000)
    }

    @Test func testRemoveAllClearsButKeepsCapacity() async {
        let recorder = WatchDiagnosticsRecorder(capacity: 4)
        await recorder.record(.routeEvent, "routeLost")
        await recorder.removeAll()
        let events = await recorder.events()
        #expect(events.isEmpty)
    }

    // MARK: - Hashing

    @Test func testSameIDAndSaltHashEqual_differentSaltDiffers() {
        let salt = Data([1, 2, 3, 4])
        let a = WatchDiagnosticsExporter.hash("req-42", salt: salt)
        let b = WatchDiagnosticsExporter.hash("req-42", salt: salt)
        let c = WatchDiagnosticsExporter.hash("req-42", salt: Data([9, 9, 9, 9]))
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 16)
    }

    // MARK: - Export redaction

    @Test func testExportHashesCorrelationIDAndOmitsRawValue() throws {
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
        #expect(export.eventCount == 2)
        #expect(export.protocolVersion == WatchProtocolVersion.current)

        let json = try WatchDiagnosticsExporter.encode(export)
        let text = String(decoding: json, as: UTF8.self)

        #expect(!text.contains(secret), "raw correlation id must never be emitted")
        #expect(!text.contains("topsecret"))
        #expect(text.contains(WatchDiagnosticsExporter.hash(secret, salt: Data([7, 7, 7, 7]))))
        #expect(text.contains("\"byteCount\" : 1234567"))
        #expect(export.entries[1].correlationHash == nil)
    }

    @Test func testExportRoundTrips() throws {
        let events = [WatchDiagnosticEvent(category: .storeRecovery, stateCode: "rebuilt",
                                           timestamp: Date(timeIntervalSince1970: 42), count: 3)]
        let export = WatchDiagnosticsExporter.export(events: events, appVersion: "1.0",
                                                     generatedAt: Date(timeIntervalSince1970: 50),
                                                     salt: Data([0]))
        let decoded = try JSONDecoder.iso8601().decode(
            WatchDiagnosticsExport.self,
            from: try WatchDiagnosticsExporter.encode(export))
        #expect(decoded == export)
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
