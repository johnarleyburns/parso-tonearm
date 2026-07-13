import Foundation

enum ReplayGain {
    enum Mode: Equatable {
        case off
        case track
        case album
    }

    struct Tags: Equatable {
        var trackGainDB: Double?
        var albumGainDB: Double?
        var trackPeak: Double?
        var albumPeak: Double?

        static let empty = Tags()
    }

    struct TagItem: Equatable {
        var key: String?
        var commonKey: String?
        var identifier: String?
        var keySpace: String?
        var stringValue: String?
        var dataValue: Data?
    }

    static func parse(items: [TagItem]) -> Tags {
        var tags = Tags()
        for item in items {
            guard let field = field(for: item),
                  let value = value(for: item, field: field) else { continue }
            switch field {
            case .trackGain:
                tags.trackGainDB = parseGainDB(value)
            case .albumGain:
                tags.albumGainDB = parseGainDB(value)
            case .trackPeak:
                tags.trackPeak = parsePeak(value)
            case .albumPeak:
                tags.albumPeak = parsePeak(value)
            }
        }
        return tags
    }

    static func appliedGain(
        mode: Mode,
        tags: Tags,
        preampDB: Double = 0,
        preventClipping: Bool = true
    ) -> Double {
        guard mode != .off else { return 1 }

        let selected: (gainDB: Double, peak: Double?)?
        switch mode {
        case .off:
            selected = nil
        case .track:
            selected = tags.trackGainDB.map { ($0, tags.trackPeak) }
        case .album:
            if let albumGain = tags.albumGainDB {
                selected = (albumGain, tags.albumPeak)
            } else {
                selected = tags.trackGainDB.map { ($0, tags.trackPeak) }
            }
        }

        guard let selected else { return 1 }
        var gain = pow(10, (selected.gainDB + preampDB) / 20)
        if preventClipping, let peak = selected.peak, peak.isFinite, peak > 0, gain * peak > 1 {
            gain = 1 / peak
        }
        return gain.isFinite && gain > 0 ? gain : 1
    }

    static func parseGainDB(_ raw: String?) -> Double? {
        number(in: raw)
    }

    static func parsePeak(_ raw: String?) -> Double? {
        guard let value = number(in: raw), value.isFinite, value > 0 else { return nil }
        return value
    }

    private enum Field {
        case trackGain
        case albumGain
        case trackPeak
        case albumPeak
    }

    private static func field(for item: TagItem) -> Field? {
        let tokens = [item.identifier, item.commonKey, item.key, item.keySpace]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if contains(tokens, field: "replaygain_track_gain") { return .trackGain }
        if contains(tokens, field: "replaygain_album_gain") { return .albumGain }
        if contains(tokens, field: "replaygain_track_peak") { return .trackPeak }
        if contains(tokens, field: "replaygain_album_peak") { return .albumPeak }

        let value = item.stringValue ?? dataString(item.dataValue) ?? ""
        let lower = value.lowercased()
        if lower.contains("replaygain_track_gain") { return .trackGain }
        if lower.contains("replaygain_album_gain") { return .albumGain }
        if lower.contains("replaygain_track_peak") { return .trackPeak }
        if lower.contains("replaygain_album_peak") { return .albumPeak }
        return nil
    }

    private static func contains(_ tokens: String, field: String) -> Bool {
        tokens.contains(field) || tokens.contains(field.replacingOccurrences(of: "_", with: " "))
    }

    private static func value(for item: TagItem, field: Field) -> String? {
        let raw = item.stringValue ?? dataString(item.dataValue)
        guard let raw else { return nil }
        let fieldName: String
        switch field {
        case .trackGain:
            fieldName = "replaygain_track_gain"
        case .albumGain:
            fieldName = "replaygain_album_gain"
        case .trackPeak:
            fieldName = "replaygain_track_peak"
        case .albumPeak:
            fieldName = "replaygain_album_peak"
        }

        let lowered = raw.lowercased()
        guard let range = lowered.range(of: fieldName) else { return raw }
        let suffix = raw[range.upperBound...]
        let trimmed = String(suffix)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}:= "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    private static func number(in raw: String?) -> Double? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let pattern = #"[-+]?\d+(?:\.\d+)?"#
        guard let range = normalized.range(of: pattern, options: .regularExpression),
              let value = Double(normalized[range]),
              value.isFinite else { return nil }
        return value
    }

    private static func dataString(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension Track {
    var replayGainTags: ReplayGain.Tags {
        ReplayGain.Tags(trackGainDB: rgTrackGain,
                        albumGainDB: rgAlbumGain,
                        trackPeak: rgTrackPeak,
                        albumPeak: rgAlbumPeak)
    }
}
