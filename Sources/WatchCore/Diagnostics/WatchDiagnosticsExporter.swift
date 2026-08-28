import Foundation
import CryptoKit
import TonearmWatchProtocol

/// The in-app diagnostics export (§12). A JSON document that carries **only**: per-export hashed
/// correlation ids, state codes, timestamps, versions, and numeric measurements — never titles,
/// URLs, credentials, tokens, paths, or search text.
///
/// Correlation ids are salted with a fresh random value per export, so the same id is not linkable
/// across two exports and the hash cannot be reversed by a dictionary attack on known id shapes.
public struct WatchDiagnosticsExport: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let category: String
        public let stateCode: String
        public let timestamp: Date
        public let correlationHash: String?
        public let durationMillis: Int?
        public let byteCount: Int64?
        public let count: Int?
    }

    public let schema: Int
    public let generatedAt: Date
    public let appVersion: String
    public let protocolVersion: Int
    public let eventCount: Int
    public let entries: [Entry]
}

public enum WatchDiagnosticsExporter {
    public static let schemaVersion = 1

    public static func randomSalt(byteCount: Int = 16) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }

    /// Salted SHA-256, truncated to 8 bytes (16 hex chars) — enough to correlate events within one
    /// export, too short and too salted to be a stable identifier across exports.
    static func hash(_ value: String, salt: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func export(events: [WatchDiagnosticEvent],
                              appVersion: String,
                              generatedAt: Date,
                              salt: Data) -> WatchDiagnosticsExport {
        let entries = events.map { event in
            WatchDiagnosticsExport.Entry(
                category: event.category.rawValue,
                stateCode: event.stateCode,
                timestamp: event.timestamp,
                correlationHash: event.correlationID.map { hash($0, salt: salt) },
                durationMillis: event.durationMillis,
                byteCount: event.byteCount,
                count: event.count)
        }
        return WatchDiagnosticsExport(schema: schemaVersion,
                                      generatedAt: generatedAt,
                                      appVersion: appVersion,
                                      protocolVersion: WatchProtocolVersion.current,
                                      eventCount: entries.count,
                                      entries: entries)
    }

    /// Encode the export as pretty JSON, keys sorted, ISO-8601 timestamps.
    public static func encode(_ export: WatchDiagnosticsExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }
}
