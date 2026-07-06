import Foundation

struct IAFile: Decodable {
    let name: String
    let format: String?
    let source: String?
    let original: String?
    let length: String?
    let size: String?
    let title: String?
    let track: String?
    let album: String?
    let artist: String?
    let bitrate: String?
    let height: String?
}

struct IAMetadataResponse: Decodable {
    struct Meta: Decodable {
        let identifier: String?
        let title: StringOrArray?
        let creator: StringOrArray?
        let mediatype: String?
        let licenseurl: String?
        let rights: String?
        let date: String?
        let year: String?
    }
    let metadata: Meta?
    let files: [IAFile]?
    let server: String?
    let dir: String?
}

/// IA JSON sometimes returns strings or arrays for the same field.
enum StringOrArray: Decodable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([String].self) { self = .array(a) }
        else { self = .string("") }
    }

    var first: String? {
        switch self {
        case .string(let s): return s.isEmpty ? nil : s
        case .array(let a): return a.first
        }
    }
}

struct ResolvedItem {
    let identifier: String
    let title: String
    let artist: String?
    let year: Int?
    let licenseText: String?
    let mediatype: String?
    let tracks: [ResolvedTrack]
}

struct ResolvedTrack {
    let title: String
    let trackNo: Int?
    let durationSec: Double?
    let codec: String?
    let sampleRate: Int?
    let bitDepthOrBitrate: String?
    let sizeBytes: Int64?
    let remoteURL: URL
    let altFlacURL: URL?
    let unsupportedReason: String?
    let sortKey: String
}

/// FR-2.2 item resolution + FR-2.5 file-selection policy.
struct ItemResolver {
    var preferFLAC: Bool = true

    func resolve(identifier: String) async throws -> ResolvedItem {
        let url = URL(string: "https://archive.org/metadata/\(identifier)")!
        let data = try await IAClient.shared.data(from: url)
        let response = try JSONDecoder().decode(IAMetadataResponse.self, from: data)

        let mediatype = response.metadata?.mediatype
        if mediatype == "movies" || mediatype == "movingimage" {
            throw IANetworkError.videoItem
        }

        let title = response.metadata?.title?.first ?? identifier
        let artist = response.metadata?.creator?.first
        let year = response.metadata.flatMap { Int($0.year ?? $0.date?.prefix(4).description ?? "") }
        let license = response.metadata?.licenseurl ?? response.metadata?.rights

        let files = response.files ?? []
        let tracks = FileSelectionPolicy(preferFLAC: preferFLAC)
            .selectTracks(files: files, identifier: identifier, itemArtist: artist)

        return ResolvedItem(identifier: identifier, title: title, artist: artist, year: year,
                            licenseText: license, mediatype: mediatype, tracks: tracks)
    }
}

struct FileSelectionPolicy {
    var preferFLAC: Bool

    /// Real audio container extensions we can stream. Opus and other unsupported
    /// formats are intentionally excluded so they never appear in a track listing.
    private static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "aif", "aiff", "ogg", "oga"
    ]

    func selectTracks(files: [IAFile], identifier: String, itemArtist: String?) -> [ResolvedTrack] {
        // 1. Candidates by real audio extension (drops opus/spectrograms/art/etc.).
        let candidates = files.filter { isCandidateAudio($0, identifier: identifier) }

        // 2. Group by the file's OWN basename stem. Format variants of the same
        //    logical track (foo.mp3 / foo.flac / foo.ogg) share a stem; distinct
        //    movements stay distinct. We deliberately do NOT group by `original`,
        //    which on many IA items points at a shared side-long rip or a
        //    segments.json and would collapse every movement into one track.
        var groups: [String: [IAFile]] = [:]
        var order: [String] = []
        for f in candidates {
            let key = baseName(f.name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }

        var results: [ResolvedTrack] = []
        for key in order {
            guard let groupFiles = groups[key], let chosen = pickPreferred(groupFiles) else { continue }
            let flacAlt = groupFiles.first { ($0.name as NSString).pathExtension.lowercased() == "flac" }
            results.append(makeTrack(chosen, flacAlt: flacAlt, identifier: identifier,
                                     fallbackArtist: itemArtist))
        }
        return results.sorted { a, b in
            switch (a.trackNo, b.trackNo) {
            case let (x?, y?) where x != y: return x < y
            default: return a.sortKey < b.sortKey
            }
        }
    }

    private func isCandidateAudio(_ f: IAFile, identifier: String) -> Bool {
        let name = f.name
        let ext = (name as NSString).pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) else { return false }
        // Skip preview samples.
        if name.lowercased().contains("_sample") { return false }
        // Skip raw side-long rips whose filename embeds the item identifier
        // (e.g. "…_disc1side1.flac"); their contents are represented by the
        // finer per-track derivatives.
        if name.lowercased().contains(identifier.lowercased()) { return false }
        return true
    }

    private func pickPreferred(_ files: [IAFile]) -> IAFile? {
        func rank(_ f: IAFile) -> Int {
            let ext = (f.name as NSString).pathExtension.lowercased()
            let fmt = (f.format ?? "").lowercased()
            let isFlac = ext == "flac" || fmt.contains("flac")
            let isMP3 = ext == "mp3" || fmt.contains("mp3")
            if preferFLAC {
                if isFlac { return 0 }
                if isMP3 { return 1 }
                return 2
            } else {
                if isMP3 { return 0 }
                if isFlac { return 1 }
                return 2
            }
        }
        return files.min { rank($0) < rank($1) }
    }

    private func makeTrack(_ f: IAFile, flacAlt: IAFile?, identifier: String,
                           fallbackArtist: String?) -> ResolvedTrack {
        let ext = (f.name as NSString).pathExtension.lowercased()
        let streamURL = URL(string: "https://archive.org/download/\(identifier)/\(escape(f.name))")!
        let flacURL: URL? = {
            guard let flacAlt, flacAlt.name != f.name else { return nil }
            return URL(string: "https://archive.org/download/\(identifier)/\(escape(flacAlt.name))")
        }()
        let codec = ext.uppercased()
        let duration = f.length.flatMap { parseDuration($0) }
        let size = f.size.flatMap { Int64($0) }
        let title = f.title ?? (f.name as NSString).lastPathComponent.replacingOccurrences(of: ".\(ext)", with: "")
        let trackNo = f.track.flatMap { Int($0.split(separator: "/").first.map(String.init) ?? $0) }
        let sortKey = String(format: "%04d_%@", trackNo ?? 9999, title.lowercased())
        return ResolvedTrack(title: title, trackNo: trackNo, durationSec: duration,
                            codec: codec, sampleRate: nil,
                            bitDepthOrBitrate: f.bitrate.map { "\($0) kbps" },
                            sizeBytes: size, remoteURL: streamURL, altFlacURL: flacURL,
                            unsupportedReason: nil, sortKey: sortKey)
    }

    private func baseName(_ name: String) -> String {
        ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func parseDuration(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
