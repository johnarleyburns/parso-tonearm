import Foundation

public enum LibraryBrowseMode: String, CaseIterable, Identifiable {
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"

    public var id: String { rawValue }
}

public enum LibraryBrowse {
    public struct Section: Identifiable, Equatable {
        public var indexTitle: String
        public var entries: [Entry]
        public var id: String { indexTitle }
    }

    public struct Entry: Identifiable, Equatable, Hashable {
        public enum Kind: String {
            case artist
            case album
            case song
            case genre
        }

        public var id: String
        public var kind: Kind
        public var title: String
        public var subtitle: String?
        public var rows: [TrackRow]
        public var indexTitle: String

        public static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id
                && lhs.kind == rhs.kind
                && lhs.title == rhs.title
                && lhs.subtitle == rhs.subtitle
                && lhs.rows == rhs.rows
                && lhs.indexTitle == rhs.indexTitle
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    public static func sections(for mode: LibraryBrowseMode, rows: [TrackRow]) -> [Section] {
        switch mode {
        case .artists: return artistSections(rows)
        case .albums: return albumSections(rows)
        case .songs: return songSections(rows)
        case .genres: return genreSections(rows)
        }
    }

    public static func indexTitle(for value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = folded.unicodeScalars.first else { return "#" }
        let scalar = Character(first).uppercased()
        guard scalar.count == 1, let ascii = scalar.unicodeScalars.first,
              (65...90).contains(Int(ascii.value)) else { return "#" }
        return scalar
    }

    private static func artistSections(_ rows: [TrackRow]) -> [Section] {
        let grouped = group(rows) { row in
            let name = artistDisplayName(row)
            return (identityKey(name), name)
        }

        let entries = grouped.map { group in
            let sortedRows = sortTracks(group.rows)
            let albumCount = Set(sortedRows.compactMap(albumIdentity)).count
            let subtitle = albumCount == 1 ? "\(sortedRows.count) songs" : "\(albumCount) albums"
            return Entry(id: "artist:\(group.key)",
                         kind: .artist,
                         title: group.title,
                         subtitle: subtitle,
                         rows: sortedRows,
                         indexTitle: indexTitle(for: ArtistNamePolicy.sortName(for: group.title)))
        }
        return sectioned(entries, sortKey: { ArtistNamePolicy.sortName(for: $0.title) })
    }

    private static func albumSections(_ rows: [TrackRow]) -> [Section] {
        let grouped = group(rows) { row in
            let albumTitle = row.album?.title.nilIfBlank ?? "Unknown Album"
            let key = row.album?.id.map { "id:\($0)" }
                ?? "fallback:\(identityKey(albumTitle)):\(identityKey(artistDisplayName(row)))"
            return (key, albumTitle)
        }

        let entries = grouped.map { group in
            let sortedRows = sortTracks(group.rows)
            let album = sortedRows.first?.album
            let artist = album?.albumArtist?.nilIfBlank
                ?? album?.artist?.nilIfBlank
                ?? artistDisplayName(sortedRows.first)
            let year = album?.year.map(String.init)
            let subtitle = [artist, year].compactMap { $0?.nilIfBlank }.joined(separator: " · ")
            return Entry(id: "album:\(group.key)",
                         kind: .album,
                         title: group.title,
                         subtitle: subtitle.nilIfBlank,
                         rows: sortedRows,
                         indexTitle: indexTitle(for: group.title))
        }
        return sectioned(entries, sortKey: { sortText($0.title) })
    }

    private static func songSections(_ rows: [TrackRow]) -> [Section] {
        let entries = rows.enumerated().map { index, row in
            Entry(id: "song:\(row.id):\(index)",
                  kind: .song,
                  title: row.track.title,
                  subtitle: songSubtitle(row),
                  rows: [row],
                  indexTitle: indexTitle(for: row.track.title))
        }
        return sectioned(entries, sortKey: { sortText($0.title) })
    }

    private static func genreSections(_ rows: [TrackRow]) -> [Section] {
        let grouped = group(rows) { row in
            let genre = row.track.genre?.nilIfBlank
                ?? row.album?.genre?.nilIfBlank
                ?? "Unknown Genre"
            return (identityKey(genre), genre)
        }

        let entries = grouped.map { group in
            let sortedRows = sortTracks(group.rows)
            return Entry(id: "genre:\(group.key)",
                         kind: .genre,
                         title: group.title,
                         subtitle: "\(sortedRows.count) songs",
                         rows: sortedRows,
                         indexTitle: indexTitle(for: group.title))
        }
        return sectioned(entries, sortKey: { sortText($0.title) })
    }

    private struct GroupedRows {
        var key: String
        var title: String
        var firstIndex: Int
        var rows: [TrackRow]
    }

    private static func group(_ rows: [TrackRow],
                              key: (TrackRow) -> (key: String, title: String)) -> [GroupedRows] {
        var groups: [String: GroupedRows] = [:]
        for (index, row) in rows.enumerated() {
            let value = key(row)
            if groups[value.key] == nil {
                groups[value.key] = GroupedRows(key: value.key, title: value.title,
                                                firstIndex: index, rows: [])
            }
            groups[value.key]?.rows.append(row)
        }
        return groups.values.sorted { lhs, rhs in
            if lhs.firstIndex != rhs.firstIndex { return lhs.firstIndex < rhs.firstIndex }
            return lhs.key < rhs.key
        }
    }

    private static func sectioned(_ entries: [Entry], sortKey: (Entry) -> String) -> [Section] {
        let sortedEntries = stableSort(entries) { sortKey($0) }
        var sectionsByIndex: [String: [Entry]] = [:]
        var indexOrder: [String] = []
        for entry in sortedEntries {
            let index = entry.indexTitle
            if sectionsByIndex[index] == nil { indexOrder.append(index) }
            sectionsByIndex[index, default: []].append(entry)
        }
        return indexOrder
            .sorted(by: compareIndexTitles)
            .map { Section(indexTitle: $0, entries: sectionsByIndex[$0] ?? []) }
    }

    private static func stableSort<T>(_ values: [T], key: (T) -> String) -> [T] {
        values.enumerated().sorted { lhs, rhs in
            let left = key(lhs.element)
            let right = key(rhs.element)
            let comparison = left.localizedStandardCompare(right)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func sortTracks(_ rows: [TrackRow]) -> [TrackRow] {
        rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.track
            let right = rhs.element.track
            let leftDisc = left.discNo ?? Int.max
            let rightDisc = right.discNo ?? Int.max
            if leftDisc != rightDisc { return leftDisc < rightDisc }
            let leftTrack = left.trackNo ?? Int.max
            let rightTrack = right.trackNo ?? Int.max
            if leftTrack != rightTrack { return leftTrack < rightTrack }
            let comparison = left.sortKey.localizedStandardCompare(right.sortKey)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func compareIndexTitles(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return false }
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs < rhs
    }

    private static func artistDisplayName(_ row: TrackRow?) -> String {
        guard let row else { return "Unknown Artist" }
        return row.album?.albumArtist?.nilIfBlank
            ?? row.album?.artist?.nilIfBlank
            ?? "Unknown Artist"
    }

    private static func songSubtitle(_ row: TrackRow) -> String? {
        let artist = artistDisplayName(row)
        let album = row.album?.title.nilIfBlank
        return [artist.nilIfBlank, album].compactMap { $0 }.joined(separator: " · ").nilIfBlank
    }

    private static func syntheticAlbumID(_ album: Album?) -> String? {
        guard let album else { return nil }
        return "\(identityKey(album.title)):\(identityKey(album.albumArtist ?? album.artist ?? ""))"
    }

    private static func albumIdentity(_ row: TrackRow) -> String? {
        if let id = row.album?.id { return "id:\(id)" }
        return syntheticAlbumID(row.album)
    }

    private static func identityKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sortText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
