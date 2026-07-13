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
    let creator: String?
    let genre: String?
    let composer: String?
    let disc: String?
    let year: String?
    let bitrate: String?
    let height: String?

    init(name: String, format: String?, source: String?, original: String?,
         length: String?, size: String?, title: String?, track: String?,
         album: String?, artist: String?, bitrate: String?, height: String?,
         creator: String? = nil, genre: String? = nil, composer: String? = nil,
         disc: String? = nil, year: String? = nil) {
        self.name = name
        self.format = format
        self.source = source
        self.original = original
        self.length = length
        self.size = size
        self.title = title
        self.track = track
        self.album = album
        self.artist = artist
        self.creator = creator
        self.genre = genre
        self.composer = composer
        self.disc = disc
        self.year = year
        self.bitrate = bitrate
        self.height = height
    }
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
        let subject: StringOrArray?
        let genre: StringOrArray?
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
    let genre: String?
    let year: Int?
    let licenseText: String?
    let mediatype: String?
    let tracks: [ResolvedTrack]
}

struct ResolvedTrack {
    let title: String
    let artist: String?
    let albumTitle: String?
    let albumArtist: String?
    let genre: String?
    let composer: String?
    let trackNo: Int?
    let discNo: Int?
    let year: Int?
    let durationSec: Double?
    let codec: String?
    let sampleRate: Int?
    let bitDepthOrBitrate: String?
    let rgTrackGain: Double?
    let rgAlbumGain: Double?
    let rgTrackPeak: Double?
    let rgAlbumPeak: Double?
    let sizeBytes: Int64?
    let remoteURL: URL
    let altFlacURL: URL?
    /// Opus derivative for this logical track, if the item offers one. Never used
    /// for cold play (AVFoundation can't demux Ogg); the prefetcher fetches and
    /// remuxes it to CAF so the next play/repeat upgrades to Opus (T2.4).
    let opusURL: URL?
    /// True when the cold-play `remoteURL` is itself Opus (an Opus-only group);
    /// playback must remux-before-play rather than stream directly.
    let requiresRemux: Bool
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
        let genre = response.metadata?.genre?.first ?? response.metadata?.subject?.first
        let license = response.metadata?.licenseurl ?? response.metadata?.rights

        let files = response.files ?? []
        let tracks = FileSelectionPolicy(preferFLAC: preferFLAC)
            .selectTracks(files: files, identifier: identifier, itemArtist: artist,
                          itemGenre: genre, itemYear: year)

        return ResolvedItem(identifier: identifier, title: title, artist: artist,
                            genre: genre, year: year,
                            licenseText: license, mediatype: mediatype,
                            tracks: tracks)
    }
}

struct FileSelectionPolicy {
    var preferFLAC: Bool

    /// Formats streamable directly by AVFoundation on a cold tap.
    private static let coldPlayableExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "aif", "aiff", "ogg", "oga"
    ]

    /// Opus is a candidate (free format via the CAF pipeline, D9) but not
    /// cold-playable: AVFoundation can't demux Ogg, so Opus goes through
    /// fetch→remux→CAF (T2.x). An Opus-only group still yields a track, flagged
    /// `requiresRemux`; mixed groups expose Opus as `opusURL` for the upgrade path.
    private static let candidateExtensions: Set<String> =
        coldPlayableExtensions.union(["opus"])

    func selectTracks(files: [IAFile], identifier: String, itemArtist: String?,
                      itemGenre: String? = nil, itemYear: Int? = nil) -> [ResolvedTrack] {
        // 1. Candidates by real audio extension (drops spectrograms/art/etc., but
        //    now keeps opus per D9).
        let candidates = files.filter { isCandidateAudio($0, identifier: identifier) }

        // 2. Group by the file's OWN basename stem. Format variants of the same
        //    logical track (foo.mp3 / foo.flac / foo.opus) share a stem; distinct
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
            let opusAlt = groupFiles.first { ($0.name as NSString).pathExtension.lowercased() == "opus" }
            results.append(makeTrack(chosen, flacAlt: flacAlt, opusAlt: opusAlt,
                                     identifier: identifier, fallbackArtist: itemArtist,
                                     fallbackGenre: itemGenre, fallbackYear: itemYear))
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
        guard Self.candidateExtensions.contains(ext) else { return false }
        // Skip preview samples.
        if name.lowercased().contains("_sample") { return false }
        // Skip raw side-long rips whose filename embeds the item identifier
        // (e.g. "…_disc1side1.flac"); their contents are represented by the
        // finer per-track derivatives.
        if name.lowercased().contains(identifier.lowercased()) { return false }
        return true
    }

    /// Explicit ranked codec policy. Lower rank wins for the cold-play pick.
    /// Opus is deliberately ranked last so a mixed group never cold-plays Opus;
    /// it only wins when it is the sole candidate (an Opus-only group).
    private func pickPreferred(_ files: [IAFile]) -> IAFile? {
        func rank(_ f: IAFile) -> Int {
            switch codecFamily(f) {
            case .flac: return preferFLAC ? 0 : 1
            case .mp3:  return preferFLAC ? 1 : 0
            case .opus: return 4
            case .other: return 3
            }
        }
        return files.min {
            let (ra, rb) = (rank($0), rank($1))
            if ra != rb { return ra < rb }
            return $0.name < $1.name
        }
    }

    private enum CodecFamily { case flac, mp3, opus, other }

    private func codecFamily(_ f: IAFile) -> CodecFamily {
        let ext = (f.name as NSString).pathExtension.lowercased()
        let fmt = (f.format ?? "").lowercased()
        if ext == "flac" || fmt.contains("flac") { return .flac }
        if ext == "mp3" || fmt.contains("mp3") { return .mp3 }
        if ext == "opus" || fmt.contains("opus") { return .opus }
        return .other
    }

    private func makeTrack(_ f: IAFile, flacAlt: IAFile?, opusAlt: IAFile?,
                           identifier: String, fallbackArtist: String?,
                           fallbackGenre: String?, fallbackYear: Int?) -> ResolvedTrack {
        let ext = (f.name as NSString).pathExtension.lowercased()
        let streamURL = downloadURL(identifier: identifier, name: f.name)!
        let flacURL: URL? = {
            guard let flacAlt, flacAlt.name != f.name else { return nil }
            return downloadURL(identifier: identifier, name: flacAlt.name)
        }()
        let opusURL: URL? = {
            guard let opusAlt else { return nil }
            return downloadURL(identifier: identifier, name: opusAlt.name)
        }()
        let requiresRemux = ext == "opus"
        let codec = ext.uppercased()
        let duration = f.length.flatMap { parseDuration($0) }
        let size = f.size.flatMap { Int64($0) }
        var fields = MetadataNormalizer.FieldBag()
        fields.title = [f.title].compactMap { $0 }
        fields.artist = [f.artist, f.creator, fallbackArtist].compactMap { $0 }
        fields.albumTitle = [f.album].compactMap { $0 }
        fields.albumArtist = [fallbackArtist].compactMap { $0 }
        fields.genre = [f.genre, fallbackGenre].compactMap { $0 }
        fields.composer = [f.composer].compactMap { $0 }
        fields.trackNumber = [f.track].compactMap { $0 }
        fields.discNumber = [f.disc].compactMap { $0 }
        fields.year = [f.year, fallbackYear.map(String.init)].compactMap { $0 }
        fields.bitDepthOrBitrate = [f.bitrate].compactMap { $0 }
        let metadata = MetadataNormalizer.normalize(fields: fields, fallbackFilename: f.name)
        let title = metadata.title ?? (f.name as NSString).lastPathComponent.replacingOccurrences(of: ".\(ext)", with: "")
        let trackNo = metadata.trackNo
        let sortKey = String(format: "%04d_%@", trackNo ?? 9999, title.lowercased())
        return ResolvedTrack(title: title,
                             artist: metadata.artist,
                             albumTitle: metadata.albumTitle,
                             albumArtist: metadata.albumArtist,
                             genre: metadata.genre,
                             composer: metadata.composer,
                             trackNo: trackNo,
                             discNo: metadata.discNo,
                             year: metadata.year,
                             durationSec: duration,
                             codec: codec, sampleRate: metadata.sampleRate,
                             bitDepthOrBitrate: metadata.bitDepthOrBitrate,
                             rgTrackGain: metadata.rgTrackGain,
                             rgAlbumGain: metadata.rgAlbumGain,
                             rgTrackPeak: metadata.rgTrackPeak,
                             rgAlbumPeak: metadata.rgAlbumPeak,
                             sizeBytes: size, remoteURL: streamURL, altFlacURL: flacURL,
                             opusURL: opusURL, requiresRemux: requiresRemux,
                             unsupportedReason: nil, sortKey: sortKey)
    }

    private func downloadURL(identifier: String, name: String) -> URL? {
        URL(string: "https://archive.org/download/\(identifier)/\(escape(name))")
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
