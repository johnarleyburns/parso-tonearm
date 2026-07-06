import Foundation
import AVFoundation
import UniformTypeIdentifiers

final class CachingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "tonearm-cache"

    private let originalURL: URL
    private let cacheKey: String
    private let session: URLSession
    private var resolvedURL: URL?
    private let stateLock = NSLock()
    private var inFlight: [Task<Void, Never>] = []
    private var didShutdown = false

    init(originalURL: URL) {
        self.originalURL = originalURL
        self.cacheKey = CachingResourceLoader.key(for: originalURL)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func shutdown() {
        stateLock.lock()
        didShutdown = true
        let tasks = inFlight
        inFlight.removeAll()
        stateLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    static func key(for url: URL) -> String {
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        return String(h, radix: 16) + "-" + (url.lastPathComponent as NSString).pathExtension.lowercased()
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
        do {
            let total = try await ensureResolvedLength()
            if let info = request.contentInformationRequest {
                info.contentLength = total
                info.isByteRangeAccessSupported = true
                info.contentType = contentType()
            }
            if let dataRequest = request.dataRequest {
                try await serve(dataRequest, total: total)
            }
            request.finishLoading()
        } catch is CancellationError { }
        catch {
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

    // MARK: - Content-length probe

    private func ensureResolvedLength() async throws -> Int64 {
        if let cached = await CacheStore.shared.totalBytes(for: cacheKey), cached > 0 {
            return cached
        }
        var request = URLRequest(url: originalURL)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("Platterhead (parso.guru)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
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
        ensureFileExists(fileURL, size: total)

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
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
            req.setValue("Platterhead (parso.guru)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: req)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            let chunkSize = 32 * 1024
            var buf: [UInt8] = []
            buf.reserveCapacity(chunkSize)

            for try await byte in bytes {
                buf.append(byte)
                if buf.count >= chunkSize {
                    try Task.checkCancellation()
                    let chunk = Data(buf)
                    writeFile(fileURL, offset: cursor, data: chunk)
                    await CacheStore.shared.recordWrite(range: cursor..<(cursor + Int64(chunk.count)), for: cacheKey)
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
                await CacheStore.shared.recordWrite(range: cursor..<(cursor + Int64(chunk.count)), for: cacheKey)
                if cursor < endRequested {
                    let usable = min(Int64(chunk.count), endRequested - cursor)
                    if usable > 0 { dr.respond(with: chunk.prefix(Int(usable))) }
                }
                cursor += Int64(chunk.count)
            }

            if cursor >= endRequested { break }
        }
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
