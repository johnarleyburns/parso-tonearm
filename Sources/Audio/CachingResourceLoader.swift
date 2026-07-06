import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// FR-3.4 CachingAssetProvider: an AVAssetResourceLoaderDelegate behind the
/// `tonearm-cache://` scheme. Serves cached ranges from a sparse file and fetches
/// misses via a shared URLSession, filling the cache as it goes. Belongs in the
/// audio engine; kept app-side here since the engine package is not vendored.
final class CachingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "tonearm-cache"

    private let originalURL: URL
    private let cacheKey: String
    private let session: URLSession
    private var resolvedURL: URL?
    private let queue = DispatchQueue(label: "guru.parso.tonearm.loader")

    init(originalURL: URL) {
        self.originalURL = originalURL
        self.cacheKey = CachingResourceLoader.key(for: originalURL)
        self.session = URLSession(configuration: .default)
        super.init()
    }

    static func key(for url: URL) -> String {
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        return String(h, radix: 16) + "-" + (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    /// Rewrite a remote https URL to the custom scheme so AVURLAsset routes through us.
    static func cacheURL(for remote: URL) -> URL {
        var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
        comps.scheme = scheme
        return comps.url ?? remote
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        Task { await self.handle(loadingRequest) }
        return true
    }

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let total = try await ensureResolvedLength()
            if let info = request.contentInformationRequest {
                info.contentLength = total
                info.isByteRangeAccessSupported = true
                info.contentType = contentType()
            }
            if let dataRequest = request.dataRequest {
                try await fulfill(dataRequest, total: total)
            }
            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
    }

    private func contentType() -> String {
        let ext = (originalURL.lastPathComponent as NSString).pathExtension.lowercased()
        switch ext {
        case "flac": return "org.xiph.flac"
        case "mp3": return UTType.mp3.identifier
        case "m4a", "aac": return UTType.mpeg4Audio.identifier
        case "wav": return UTType.wav.identifier
        case "aif", "aiff": return UTType.aiff.identifier
        default: return UTType.audio.identifier
        }
    }

    // MARK: - Resolution

    private func ensureResolvedLength() async throws -> Int64 {
        if let cached = await CacheStore.shared.totalBytes(for: cacheKey), cached > 0 {
            return cached
        }
        var request = URLRequest(url: originalURL)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue("Platterhead (parso.guru)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        self.resolvedURL = http.url ?? originalURL
        let total = Self.totalLength(from: http)
        if total > 0 { await CacheStore.shared.setContentLength(total, for: cacheKey) }
        return total
    }

    private static func totalLength(from http: HTTPURLResponse) -> Int64 {
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.split(separator: "/").last, let total = Int64(slash) {
            return total
        }
        if http.expectedContentLength > 0 { return http.expectedContentLength }
        return 0
    }

    // MARK: - Serving data

    private func fulfill(_ dataRequest: AVAssetResourceLoadingDataRequest, total: Int64) async throws {
        let start = dataRequest.currentOffset
        let requestedLength = Int64(dataRequest.requestedLength)
        var end = start + requestedLength
        if total > 0 { end = min(end, total) }
        guard end > start else { return }

        let fileURL = await CacheStore.shared.fileURL(for: cacheKey)
        ensureFileExists(fileURL, size: total)

        var offset = start
        while offset < end {
            let map = await CacheStore.shared.rangeMap(for: cacheKey)
            let available = map.contiguousBytes(from: offset)
            if available > 0 {
                let chunkEnd = min(offset + available, end)
                if let data = readFile(fileURL, offset: offset, length: chunkEnd - offset) {
                    dataRequest.respond(with: data)
                }
                offset = chunkEnd
            } else {
                let fetchEnd = min(end + 256 * 1024, total > 0 ? total : end + 256 * 1024)
                let fetched = try await fetchRange(offset..<fetchEnd)
                writeFile(fileURL, offset: offset, data: fetched)
                await CacheStore.shared.recordWrite(range: offset..<(offset + Int64(fetched.count)), for: cacheKey)
                let usable = min(Int64(fetched.count), end - offset)
                if usable > 0 {
                    dataRequest.respond(with: fetched.prefix(Int(usable)))
                }
                offset += Int64(fetched.count)
                if fetched.isEmpty { break }
            }
        }
    }

    private func fetchRange(_ range: Range<Int64>) async throws -> Data {
        let url = resolvedURL ?? originalURL
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("Platterhead (parso.guru)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return data
    }

    // MARK: - Sparse file IO

    private func ensureFileExists(_ url: URL, size: Int64) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
            if size > 0, let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: UInt64(size))
                try? handle.close()
            }
        }
    }

    private func readFile(_ url: URL, offset: Int64, length: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: Int(length))
    }

    private func writeFile(_ url: URL, offset: Int64, data: Data) {
        guard !data.isEmpty, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        try? handle.write(contentsOf: data)
    }
}
