import Foundation

/// File-backed index of recorded mixes (My Music > Mixes) saved from the manual DJ console's REC
/// button. An actor, so concurrent saves/removals are serialised; every write is atomic and the
/// in-memory state only updates after the write succeeds, so a failure cannot leave a duplicate or
/// half-written entry behind. Mirrors `BlendRepository`'s shape, minus the legacy-migration
/// handling that model needed and this one, being new, does not.
public actor MixRecordingRepository {
    public enum RepositoryError: Error, Equatable {
        case writeFailed(String)
    }

    public enum LoadIssue: Sendable, Equatable {
        /// The index file could not be decoded; it was moved aside, not deleted.
        case malformedQuarantined(String)
    }

    public struct Snapshot: Sendable, Equatable {
        public var mixes: [MixRecordingDocument]
        public var issues: [LoadIssue]
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var mixes: [MixRecordingDocument]
    }
    private static let currentSchemaVersion = 1

    private let indexURL: URL
    private var mixes: [MixRecordingDocument] = []
    private var issues: [LoadIssue] = []
    private var loaded = false

    public init(indexURL: URL) { self.indexURL = indexURL }

    public func load() -> Snapshot {
        if !loaded { performLoad(); loaded = true }
        return Snapshot(mixes: sorted(), issues: issues)
    }

    public func mix(id: UUID) -> MixRecordingDocument? {
        _ = load()
        return mixes.first { $0.id == id }
    }

    @discardableResult
    public func save(_ document: MixRecordingDocument) throws -> MixRecordingDocument {
        _ = load()
        var next = mixes
        if let i = next.firstIndex(where: { $0.id == document.id }) { next[i] = document }
        else { next.append(document) }
        try write(next)
        mixes = next
        return document
    }

    /// Removes only the document with this id; absent ids are a no-op. The caller is responsible
    /// for deleting the underlying FLAC file — this repository only ever touches the index.
    public func remove(id: UUID) throws {
        _ = load()
        let next = mixes.filter { $0.id != id }
        guard next.count != mixes.count else { return }
        try write(next)
        mixes = next
    }

    public func rename(id: UUID, title: String) throws {
        _ = load()
        guard var doc = mixes.first(where: { $0.id == id }) else { return }
        doc.title = title
        _ = try save(doc)
    }

    private func sorted() -> [MixRecordingDocument] {
        mixes.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    private func write(_ docs: [MixRecordingDocument]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: Self.currentSchemaVersion, mixes: docs))
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw RepositoryError.writeFailed(String(describing: error))
        }
    }

    private func performLoad() {
        guard let data = try? Data(contentsOf: indexURL) else { return } // no file: empty, not an error
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            quarantine(); return
        }
        mixes = env.mixes
    }

    private func quarantine() {
        let aside = indexURL.appendingPathExtension("malformed-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: indexURL, to: aside)
        issues.append(.malformedQuarantined(aside.lastPathComponent))
    }
}
