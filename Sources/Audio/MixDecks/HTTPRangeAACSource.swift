#if !os(watchOS)
import Foundation
import ParsoAudioStreaming

/// Sparse, verified transport for a release AAC asset. It intentionally deals
/// only in bytes; the feeder/decoder owns PCM. No response body is admitted to
/// the cache until a valid 206 range has been received.
actor HTTPRangeAACSource {
    struct Descriptor: Sendable, Equatable {
        var assetID: String
        var url: URL
        var headers: [String: String]
        var expectedLength: Int64
    }
    enum Error: Swift.Error, LocalizedError { case permanent(Int), malformedResponse, deadline
        var errorDescription: String? { "Range audio source unavailable" }
    }

    typealias Refresh = @Sendable () async throws -> Descriptor
    private var descriptor: Descriptor
    private let cache: SparseCacheStore
    private let refresh: Refresh?
    private let session: URLSession

    init(descriptor: Descriptor, cache: SparseCacheStore, refresh: Refresh? = nil,
         session: URLSession = .shared) {
        self.descriptor = descriptor; self.cache = cache; self.refresh = refresh; self.session = session
    }

    func require(_ range: Range<Int64>, deadline: Date) async throws -> URL {
        guard Date() < deadline else { throw Error.deadline }
        let key = descriptor.assetID
        let cached = await cache.cachedContiguousBytes(for: key, from: range.lowerBound)
        if cached >= range.count { return await cache.fileURL(for: key) }
        try await fetch(range, deadline: deadline, refreshed: false)
        return await cache.fileURL(for: key)
    }

    private func fetch(_ range: Range<Int64>, deadline: Date, refreshed: Bool) async throws {
        var last: Swift.Error = Error.malformedResponse
        for attempt in 0..<4 {
            guard Date() < deadline else { throw Error.deadline }
            do {
                var request = URLRequest(url: descriptor.url)
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                descriptor.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw Error.malformedResponse }
                if (http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 416), !refreshed, let refresh {
                    descriptor = try await refresh(); try await fetch(range, deadline: deadline, refreshed: true); return
                }
                guard http.statusCode == 206,
                      Int64(data.count) == range.count,
                      validContentRange(http.value(forHTTPHeaderField: "Content-Range"), expected: range) else {
                    if http.statusCode == 408 || http.statusCode == 425 || http.statusCode == 429 || http.statusCode >= 500 {
                        throw URLError(.cannotLoadFromNetwork)
                    }
                    throw Error.permanent(http.statusCode)
                }
                let file = await cache.fileURL(for: descriptor.assetID)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(range.lowerBound)); try handle.write(contentsOf: data)
                await cache.setContentLength(descriptor.expectedLength, for: descriptor.assetID)
                await cache.recordWrite(range: range, for: descriptor.assetID)
                return
            } catch let error as Error { throw error
            } catch { last = error }
            if attempt < 3 { try await Task.sleep(for: [.milliseconds(250), .seconds(1), .seconds(4)][attempt]) }
        }
        throw last
    }

    private func validContentRange(_ value: String?, expected: Range<Int64>) -> Bool {
        guard let value else { return false }
        let prefix = "bytes \\(expected.lowerBound)-\\(expected.upperBound - 1)/"
        guard value.hasPrefix(prefix), let total = Int64(value.dropFirst(prefix.count)) else { return false }
        return total == descriptor.expectedLength
    }
}
#endif
