import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

final class CachingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "tonearm-cache"

    private let originalURL: URL
    private let headers: [String: String]
    let cacheKey: String
    private var resolvedURL: URL?
    private let stateLock = NSLock()
    private var inFlight: [Task<Void, Never>] = []
    private var didShutdown = false
    private var fileHandle: FileHandle?

    init(originalURL: URL, headers: [String: String] = [:]) {
        self.originalURL = originalURL
        self.headers = headers
        self.cacheKey = CachingResourceLoader.key(for: originalURL)
        super.init()
    }

    deinit {
        if let h = fileHandle { try? h.close() }
    }

    /// Shared session: avoids per-loader `URLSession` leaks (F8). One session for
    /// all resource loader instances; individual requests are aborted via cancel.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    func shutdown() {
        stateLock.lock()
        didShutdown = true
        let tasks = inFlight
        inFlight.removeAll()
        stateLock.unlock()
        tasks.forEach { $0.cancel() }
        if let h = fileHandle { try? h.close(); fileHandle = nil }
    }

    /// Prefetch-triggered cache fill (F4): walks the same cache-filling path as the
    /// resource loader at background priority, without involving AVFoundation. The
    /// loader must not be shut down; callers should retain a reference until warm
    /// completes or is cancelled via `shutdown()`.
    func warm(upTo bytes: Int64) {
        let key = cacheKey
        let url = originalURL
        let hdrs = headers
        Task.detached(priority: .background) {
            guard bytes > 0 else { return }
            let fileURL = await CacheStore.shared.fileURL(for: key)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            var rangeHeader = "bytes=0-\(bytes - 1)"
            // respect existing cache so we don't re-download
            let map = await CacheStore.shared.rangeMap(for: key)
            let already = map.contiguousBytes(from: 0)
            guard already < bytes else { return }
            rangeHeader = "bytes=\(already)-\(bytes - 1)"
            var req = URLRequest(url: url)
            for (field, value) in hdrs { req.setValue(value, forHTTPHeaderField: field) }
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
            do {
                let (body, response) = try await Self.session.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 206 else { return }
                guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                      let startStr = contentRange.split(separator: " ").dropFirst().first?
                        .split(separator: "-").first,
                      let rangeStart = Int64(startStr),
                      rangeStart == already else { return }
                let fh = try FileHandle(forWritingTo: fileURL)
                defer { try? fh.close() }
                try fh.seek(toOffset: UInt64(already))
                try fh.write(contentsOf: body)
                let end = already + Int64(body.count)
                await CacheStore.shared.recordWrite(range: already..<end, for: key)
            } catch {}
        }
    }

    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return hex + "-" + (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    static func cacheURL(for remote: URL) -> URL {
        var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
        comps.scheme = scheme
        return comps.url ?? remote
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        stateLock.lock()
        guard !didShutdown else { stateLock.unlock(); return false }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handle(loadingRequest)
        }
        inFlight.append(task)
        stateLock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) { }

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        guard !request.isCancelled else { return }
        do {
            let total = try await ensureResolvedLength()
            guard !request.isCancelled else { return }
            if let info = request.contentInformationRequest {
                info.contentLength = total
                info.isByteRangeAccessSupported = true
                info.contentType = contentType()
            }
            if let dataRequest = request.dataRequest, !request.isCancelled {
                try await serve(dataRequest, total: total)
            }
            guard !request.isCancelled else { return }
            request.finishLoading()
        } catch is CancellationError { }
        catch {
            request.finishLoading(with: error)
        }
    }

    private func contentType() -> String {
        Self.contentType(for: originalURL)
    }

    /// Maps a remote audio URL to a UTI for AVFoundation. Uses the path extension
    /// only, so IA download URLs carrying a query string (e.g. `?cnt=…`) still map
    /// correctly — `pathExtension` ignores the query component.
    static func contentType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "flac": return "org.xiph.flac"
        case "mp3": return UTType.mp3.identifier
        case "m4a", "aac": return UTType.mpeg4Audio.identifier
        case "wav": return UTType.wav.identifier
        case "aif", "aiff": return UTType.aiff.identifier
        default: return UTType.audio.identifier
        }
    }

    // MARK: - Content-length probe

    private func ensureResolvedLength() async throws -> Int64 {
        if let cached = await CacheStore.shared.totalBytes(for: cacheKey), cached > 0 {
            return cached
        }
        var request = URLRequest(url: originalURL)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 206 else { throw URLError(.badServerResponse) }
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

    // MARK: - Progressive streaming serve

    private func serve(_ dr: AVAssetResourceLoadingDataRequest, total: Int64) async throws {
        let start = dr.currentOffset
        let requestedLength = Int64(dr.requestedLength)
        var endRequested: Int64
        if dr.requestsAllDataToEndOfResource {
            endRequested = total > 0 ? total : Int64.max
        } else {
            endRequested = start + requestedLength
        }
        if total > 0 { endRequested = min(endRequested, total) }
        guard endRequested > start else { return }

        let fileURL = await CacheStore.shared.fileURL(for: cacheKey)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        var cursor = start

        while cursor < endRequested {
            try Task.checkCancellation()

            let map = await CacheStore.shared.rangeMap(for: cacheKey)
            let cachedContiguous = map.contiguousBytes(from: cursor)

            if cachedContiguous > 0 {
                let chunkEnd = min(cursor + cachedContiguous, endRequested)
                if let data = readFile(fileURL, offset: cursor, length: chunkEnd - cursor) {
                    dr.respond(with: data)
                }
                cursor = chunkEnd
                continue
            }

            let rangeHeader: String
            if endRequested < Int64.max && total > 0 {
                rangeHeader = "bytes=\(cursor)-\(endRequested - 1)"
            } else if total > 0, cursor < total {
                rangeHeader = "bytes=\(cursor)-\(total - 1)"
            } else {
                rangeHeader = "bytes=\(cursor)-"
            }

            let url = resolvedURL ?? originalURL
            var req = URLRequest(url: url)
            for (field, value) in headers {
                req.setValue(value, forHTTPHeaderField: field)
            }
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
            let (bytes, response) = try await Self.session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            switch http.statusCode {
            case 206:
                guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                      let rangeStart = contentRange.split(separator: " ").dropFirst().first
                        .flatMap({ $0.split(separator: "-").first }).flatMap({ Int64($0) }),
                      rangeStart == cursor else {
                    throw URLError(.badServerResponse)
                }
            case 200 where cursor == 0:
                let cl = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
                guard cl > 0, let t = await CacheStore.shared.totalBytes(for: cacheKey), t > 0, cl == t else {
                    throw URLError(.badServerResponse)
                }
            default:
                throw URLError(.badServerResponse)
            }

            let chunkSize = 32 * 1024
            var buf: [UInt8] = []
            buf.reserveCapacity(chunkSize)
            var chunkRanges: [Range<Int64>] = []
            let networkCursor = cursor

            for try await byte in bytes {
                buf.append(byte)
                if buf.count >= chunkSize {
                    try Task.checkCancellation()
                    let chunk = Data(buf)
                    writeFile(fileURL, offset: cursor, data: chunk)
                    chunkRanges.append(cursor..<(cursor + Int64(chunk.count)))
                    if cursor < endRequested {
                        let usable = min(Int64(chunk.count), endRequested - cursor)
                        if usable > 0 { dr.respond(with: chunk.prefix(Int(usable))) }
                    }
                    cursor += Int64(chunk.count)
                    buf.removeAll(keepingCapacity: true)
                }
            }

            if !buf.isEmpty {
                let chunk = Data(buf)
                writeFile(fileURL, offset: cursor, data: chunk)
                chunkRanges.append(cursor..<(cursor + Int64(chunk.count)))
                if cursor < endRequested {
                    let usable = min(Int64(chunk.count), endRequested - cursor)
                    if usable > 0 { dr.respond(with: chunk.prefix(Int(usable))) }
                }
                cursor += Int64(chunk.count)
            }

            for range in chunkRanges.reversed() {
                await CacheStore.shared.recordWrite(range: range, for: cacheKey)
            }

            if cursor >= endRequested { break }
        }
    }

    // MARK: - Sparse file IO

    private func readFile(_ url: URL, offset: Int64, length: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: Int(length))
    }

    private func writeFile(_ url: URL, offset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: url)
        }
        guard let handle = fileHandle else { return }
        try? handle.seek(toOffset: UInt64(offset))
        try? handle.write(contentsOf: data)
    }
}
