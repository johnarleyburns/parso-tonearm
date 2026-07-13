import Foundation

struct TrackMetadata: Equatable {
    var title: String?
    var artist: String?
    var albumTitle: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var trackNo: Int?
    var discNo: Int?
    var year: Int?
    var durationSec: Double?
    var sampleRate: Int?
    var bitDepthOrBitrate: String?
    var rgTrackGain: Double?
    var rgAlbumGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumPeak: Double?
}

struct MetadataNormalizer {
    struct Item: Equatable {
        var key: String?
        var commonKey: String?
        var identifier: String?
        var keySpace: String?
        var stringValue: String?
        var numberValue: Double?
        var dataValue: Data?
    }

    struct FieldBag: Equatable {
        var title: [String] = []
        var artist: [String] = []
        var albumTitle: [String] = []
        var albumArtist: [String] = []
        var genre: [String] = []
        var composer: [String] = []
        var trackNumber: [String] = []
        var discNumber: [String] = []
        var year: [String] = []
        var bitDepthOrBitrate: [String] = []
        var replayGainTrackGain: [String] = []
        var replayGainAlbumGain: [String] = []
        var replayGainTrackPeak: [String] = []
        var replayGainAlbumPeak: [String] = []
    }

    private enum Field {
        case title
        case artist
        case albumTitle
        case albumArtist
        case genre
        case composer
        case trackNumber
        case discNumber
        case year
        case bitDepthOrBitrate
    }

    private struct Candidate {
        var value: String
        var priority: Int
        var order: Int
    }

    static func normalize(items: [Item], fallbackFilename: String) -> TrackMetadata {
        var candidates: [Field: [Candidate]] = [:]

        for (order, item) in items.enumerated() {
            guard let field = classify(item) else { continue }
            guard let value = valueString(for: item, field: field) else { continue }
            candidates[field, default: []].append(
                Candidate(value: value, priority: priority(for: item), order: order))
        }

        var metadata = normalize(candidates: candidates, fallbackFilename: fallbackFilename)
        metadata.apply(replayGain: ReplayGain.parse(items: items.map {
            ReplayGain.TagItem(
                key: $0.key,
                commonKey: $0.commonKey,
                identifier: $0.identifier,
                keySpace: $0.keySpace,
                stringValue: $0.stringValue,
                dataValue: $0.dataValue)
        }))
        return metadata
    }

    static func normalize(fields: FieldBag, fallbackFilename: String) -> TrackMetadata {
        var candidates: [Field: [Candidate]] = [:]

        func add(_ field: Field, _ values: [String]) {
            for (order, value) in values.enumerated() {
                candidates[field, default: []].append(
                    Candidate(value: value, priority: 0, order: order))
            }
        }

        add(.title, fields.title)
        add(.artist, fields.artist)
        add(.albumTitle, fields.albumTitle)
        add(.albumArtist, fields.albumArtist)
        add(.genre, fields.genre)
        add(.composer, fields.composer)
        add(.trackNumber, fields.trackNumber)
        add(.discNumber, fields.discNumber)
        add(.year, fields.year)
        add(.bitDepthOrBitrate, fields.bitDepthOrBitrate)

        var metadata = normalize(candidates: candidates, fallbackFilename: fallbackFilename)
        metadata.apply(replayGain: ReplayGain.Tags(
            trackGainDB: fields.replayGainTrackGain.lazy.compactMap(ReplayGain.parseGainDB).first,
            albumGainDB: fields.replayGainAlbumGain.lazy.compactMap(ReplayGain.parseGainDB).first,
            trackPeak: fields.replayGainTrackPeak.lazy.compactMap(ReplayGain.parsePeak).first,
            albumPeak: fields.replayGainAlbumPeak.lazy.compactMap(ReplayGain.parsePeak).first))
        return metadata
    }

    private static func normalize(
        candidates: [Field: [Candidate]],
        fallbackFilename: String
    ) -> TrackMetadata {
        let fallback = FilenameQueryParser().parse(fallbackFilename)
        let fallbackTitle = fallback.title ?? fallback.cleanedTerm.nilIfEmpty

        var metadata = TrackMetadata()
        metadata.title = clean(best(.title, candidates)) ?? fallbackTitle
        metadata.artist = ArtistNamePolicy.normalize(best(.artist, candidates) ?? fallback.artist)
        metadata.albumTitle = clean(best(.albumTitle, candidates))
        metadata.albumArtist = ArtistNamePolicy.normalize(best(.albumArtist, candidates))
        metadata.genre = clean(best(.genre, candidates))
        metadata.composer = ArtistNamePolicy.normalize(best(.composer, candidates))
        metadata.trackNo = parseIndexedNumber(best(.trackNumber, candidates))
            ?? leadingTrackNumber(in: fallbackFilename)
        metadata.discNo = parseIndexedNumber(best(.discNumber, candidates))
        metadata.year = parseYear(best(.year, candidates))
        metadata.bitDepthOrBitrate = normalizeAudioDepth(best(.bitDepthOrBitrate, candidates))
        return metadata
    }

    private static func best(_ field: Field, _ candidates: [Field: [Candidate]]) -> String? {
        candidates[field]?
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.order < $1.order
            }
            .lazy
            .compactMap { clean($0.value) }
            .first
    }

    private static func classify(_ item: Item) -> Field? {
        let tokens = [item.identifier, item.commonKey, item.key, item.keySpace]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if containsAny(tokens, ["albumartist", "album artist", "album_artist", "aart", "tpe2"]) {
            return .albumArtist
        }
        if containsAny(tokens, ["tracknumber", "track number", "trck", "trkn"]) {
            return .trackNumber
        }
        if containsAny(tokens, ["discnumber", "disc number", "disk", "tpos"]) {
            return .discNumber
        }
        if containsAny(tokens, ["albumname", "album name", "album", "talb", "©alb"]) {
            return .albumTitle
        }
        if containsAny(tokens, ["composer", "writer", "tcom", "©wrt"]) {
            return .composer
        }
        if containsAny(tokens, ["genre", "tcon", "©gen"]) {
            return .genre
        }
        if containsAny(tokens, ["artist", "author", "creator", "tpe1", "©art"]) {
            return .artist
        }
        if containsAny(tokens, ["title", "name", "tit2", "©nam"]) {
            return .title
        }
        if containsAny(tokens, ["year", "date", "tyer", "tdrc", "©day"]) {
            return .year
        }
        if containsAny(tokens, ["bitrate", "bit depth", "bitdepth"]) {
            return .bitDepthOrBitrate
        }
        return nil
    }

    private static func priority(for item: Item) -> Int {
        let tokens = [item.identifier, item.commonKey, item.keySpace]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if item.commonKey != nil || tokens.contains("common") { return 0 }
        if tokens.contains("itunes") || tokens.contains("itsk") { return 1 }
        if tokens.contains("id3") { return 2 }
        return 3
    }

    private static func valueString(for item: Item, field: Field) -> String? {
        switch field {
        case .trackNumber, .discNumber:
            if let string = clean(item.stringValue) { return string }
            if let number = item.numberValue, number.isFinite { return String(Int(number)) }
            return parseITunesIndexedNumber(item.dataValue).map(String.init)
        case .year:
            if let string = clean(item.stringValue) { return string }
            if let number = item.numberValue, number.isFinite { return String(Int(number)) }
            return nil
        default:
            if let string = clean(item.stringValue) { return string }
            if let number = item.numberValue, number.isFinite { return String(number) }
            guard let data = item.dataValue else { return nil }
            return String(data: data, encoding: .utf8).flatMap(clean)
        }
    }

    private static func parseIndexedNumber(_ raw: String?) -> Int? {
        guard let raw = clean(raw) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits.unicodeScalars.append(scalar)
            } else if digits.isEmpty {
                continue
            } else {
                break
            }
        }
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    private static func parseYear(_ raw: String?) -> Int? {
        guard let raw = clean(raw) else { return nil }
        let scalars = Array(raw.unicodeScalars)
        for index in scalars.indices where index + 3 < scalars.endIndex {
            let slice = scalars[index...(index + 3)]
            guard slice.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) else { continue }
            let value = String(String.UnicodeScalarView(slice))
            if let year = Int(value), (1000...2999).contains(year) { return year }
        }
        return nil
    }

    private static func parseITunesIndexedNumber(_ data: Data?) -> Int? {
        guard let bytes = data.map(Array.init), bytes.count >= 4 else { return nil }
        let candidates: [(Int, Int)] = [(2, 3), (0, 1)]
        for (highIndex, lowIndex) in candidates where lowIndex < bytes.count {
            let value = Int(bytes[highIndex]) << 8 | Int(bytes[lowIndex])
            if value > 0 { return value }
        }
        return nil
    }

    private static func leadingTrackNumber(in filename: String) -> Int? {
        let stem = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber, digits.count < 3 {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard !digits.isEmpty, index < trimmed.endIndex else { return nil }
        let separator = trimmed[index]
        guard separator == " " || separator == "-" || separator == "." || separator == "_" else {
            return nil
        }
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    private static func normalizeAudioDepth(_ raw: String?) -> String? {
        guard let value = clean(raw) else { return nil }
        let lower = value.lowercased()
        if lower.contains("bit") || lower.contains("kbps") || lower.contains("khz") {
            return value
        }
        if let number = Int(value), number > 0 {
            return "\(number) kbps"
        }
        return value
    }

    private static func containsAny(_ source: String, _ needles: [String]) -> Bool {
        needles.contains { source.contains($0) }
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension TrackMetadata {
    mutating func apply(replayGain tags: ReplayGain.Tags) {
        rgTrackGain = tags.trackGainDB
        rgAlbumGain = tags.albumGainDB
        rgTrackPeak = tags.trackPeak
        rgAlbumPeak = tags.albumPeak
    }
}
