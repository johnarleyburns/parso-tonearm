import CryptoKit
import Foundation

public enum SubsonicAPI {
    public static let defaultVersion = "1.16.1"
    public static let defaultClient = "Tonearm"

    public enum Format: String, Equatable {
        case json
        case xml
    }

    public enum Endpoint: Equatable {
        case ping
        case getArtists
        case getIndexes
        case getArtist(id: String)
        case getAlbum(id: String)
        case stream(id: String)
        case coverArt(id: String)

        var method: String {
            switch self {
            case .ping: return "ping.view"
            case .getArtists: return "getArtists.view"
            case .getIndexes: return "getIndexes.view"
            case .getArtist: return "getArtist.view"
            case .getAlbum: return "getAlbum.view"
            case .stream: return "stream.view"
            case .coverArt: return "getCoverArt.view"
            }
        }

        var queryItems: [URLQueryItem] {
            switch self {
            case .ping, .getArtists, .getIndexes:
                return []
            case .getArtist(let id), .getAlbum(let id), .stream(let id), .coverArt(let id):
                return [URLQueryItem(name: "id", value: id)]
            }
        }
    }

    public struct Auth: Equatable {
        var username: String
        var password: String
        var salt: String
        var apiVersion: String = SubsonicAPI.defaultVersion
        var client: String = SubsonicAPI.defaultClient
    }

    public enum Error: Swift.Error, Equatable {
        case invalidBaseURL
        case malformedResponse
        case missingField(String)
        case remote(code: Int, message: String)
    }

    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.invalidBaseURL }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw Error.invalidBaseURL
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path != "/" {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !components.path.isEmpty {
                components.path = "/\(components.path)"
            }
        }
        guard let url = components.url else { throw Error.invalidBaseURL }
        return url
    }

    public static func token(password: String, salt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public static func url(baseURL rawBaseURL: URL,
                    endpoint: Endpoint,
                    auth: Auth,
                    format: Format = .json) throws -> URL {
        let baseURL = try normalizeBaseURL(rawBaseURL.absoluteString)
        let endpointURL = baseURL
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent(endpoint.method)
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw Error.invalidBaseURL
        }
        components.queryItems = [
            URLQueryItem(name: "u", value: auth.username),
            URLQueryItem(name: "t", value: token(password: auth.password, salt: auth.salt)),
            URLQueryItem(name: "s", value: auth.salt),
            URLQueryItem(name: "v", value: auth.apiVersion),
            URLQueryItem(name: "c", value: auth.client),
            URLQueryItem(name: "f", value: format.rawValue),
        ] + endpoint.queryItems
        guard let url = components.url else { throw Error.invalidBaseURL }
        return url
    }

    public static func decodePing(_ data: Data, format: Format) throws {
        _ = try responseRoot(data, format: format)
    }

    public static func decodeArtists(_ data: Data, format: Format) throws -> [SubsonicArtist] {
        switch format {
        case .json:
            let root = try responseRoot(data, format: format).json
            let container = dictionary(root["artists"]) ?? dictionary(root["indexes"])
            guard let container else { return [] }
            var artists: [SubsonicArtist] = []
            for index in dictionaries(container["index"]) {
                artists.append(contentsOf: dictionaries(index["artist"]).map(decodeArtist))
            }
            if artists.isEmpty {
                artists.append(contentsOf: dictionaries(container["artist"]).map(decodeArtist))
            }
            return artists
        case .xml:
            return try responseRoot(data, format: format).xml.artists
        }
    }

    public static func decodeArtist(_ data: Data, format: Format) throws -> SubsonicArtistDetail {
        switch format {
        case .json:
            let root = try responseRoot(data, format: format).json
            guard let artist = dictionary(root["artist"]) else { throw Error.missingField("artist") }
            let id = try requiredString(artist["id"], field: "artist.id")
            let name = string(artist["name"]) ?? id
            let albums = dictionaries(artist["album"]).map(decodeAlbumSummary)
            return SubsonicArtistDetail(id: id, name: name, albums: albums)
        case .xml:
            let collector = try responseRoot(data, format: format).xml
            guard var detail = collector.artistDetail else { throw Error.missingField("artist") }
            detail.albums = collector.albumSummaries
            return detail
        }
    }

    public static func decodeAlbum(_ data: Data, format: Format) throws -> SubsonicAlbum {
        switch format {
        case .json:
            let root = try responseRoot(data, format: format).json
            guard let album = dictionary(root["album"]) else { throw Error.missingField("album") }
            var decoded = decodeAlbumDetail(album)
            decoded.songs = dictionaries(album["song"]).map(decodeSong)
            return decoded
        case .xml:
            let collector = try responseRoot(data, format: format).xml
            guard var album = collector.album else { throw Error.missingField("album") }
            album.songs = collector.songs
            return album
        }
    }

    private struct ParsedResponse {
        var json: [String: Any] = [:]
        var xml: XMLCollector = XMLCollector()
    }

    private static func responseRoot(_ data: Data, format: Format) throws -> ParsedResponse {
        switch format {
        case .json:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let root = dictionary(object["subsonic-response"]) else {
                throw Error.malformedResponse
            }
            try validate(status: string(root["status"]), error: dictionary(root["error"]))
            return ParsedResponse(json: root)
        case .xml:
            let collector = XMLCollector()
            let parser = XMLParser(data: data)
            parser.delegate = collector
            guard parser.parse() else { throw Error.malformedResponse }
            guard collector.sawResponse else { throw Error.malformedResponse }
            try validate(status: collector.status, error: collector.error?.dictionary)
            return ParsedResponse(xml: collector)
        }
    }

    private static func validate(status: String?, error: [String: Any]?) throws {
        if status == "failed" {
            let code = int(error?["code"]) ?? 0
            let message = string(error?["message"]) ?? "Subsonic request failed"
            throw Error.remote(code: code, message: message)
        }
        guard status == nil || status == "ok" else { throw Error.malformedResponse }
    }

    private static func decodeArtist(_ dict: [String: Any]) -> SubsonicArtist {
        let id = string(dict["id"]) ?? ""
        return SubsonicArtist(
            id: id,
            name: string(dict["name"]) ?? id,
            albumCount: int(dict["albumCount"])
        )
    }

    private static func decodeAlbumSummary(_ dict: [String: Any]) -> SubsonicAlbumSummary {
        let id = string(dict["id"]) ?? ""
            return SubsonicAlbumSummary(
                id: id,
                name: string(dict["name"]) ?? id,
                artist: string(dict["artist"]),
                artistId: string(dict["artistId"]),
                songCount: int(dict["songCount"]),
                year: int(dict["year"]),
                genre: string(dict["genre"]),
                coverArt: string(dict["coverArt"])
            )
        }

    private static func decodeAlbumDetail(_ dict: [String: Any]) -> SubsonicAlbum {
        let id = string(dict["id"]) ?? ""
            return SubsonicAlbum(
                id: id,
                name: string(dict["name"]) ?? id,
                artist: string(dict["artist"]),
                artistId: string(dict["artistId"]),
                year: int(dict["year"]),
                genre: string(dict["genre"]),
                coverArt: string(dict["coverArt"]),
                songs: []
            )
        }

    private static func decodeSong(_ dict: [String: Any]) -> SubsonicSong {
        let id = string(dict["id"]) ?? ""
        return SubsonicSong(
            id: id,
            title: string(dict["title"]) ?? id,
            album: string(dict["album"]),
            albumId: string(dict["albumId"]),
            artist: string(dict["artist"]),
            artistId: string(dict["artistId"]),
            track: int(dict["track"]) ?? int(dict["trackNumber"]),
            discNumber: int(dict["discNumber"]),
            duration: double(dict["duration"]),
            suffix: string(dict["suffix"]),
            contentType: string(dict["contentType"]),
            size: int64(dict["size"]),
            bitRate: int(dict["bitRate"]),
            samplingRate: int(dict["samplingRate"]),
            coverArt: string(dict["coverArt"])
        )
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let decoded = string(value), !decoded.isEmpty else {
            throw Error.missingField(field)
        }
        return decoded
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        if let dict = value as? [String: Any] { return [dict] }
        return value as? [[String: Any]] ?? []
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let int = value as? Int64 { return int }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public struct SubsonicArtist: Equatable {
    public var id: String
    public var name: String
    public var albumCount: Int?
}

public struct SubsonicArtistDetail: Equatable {
    public var id: String
    public var name: String
    public var albums: [SubsonicAlbumSummary]
}

public struct SubsonicAlbumSummary: Equatable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artistId: String?
    public var songCount: Int?
    public var year: Int?
    public var genre: String?
    public var coverArt: String? = nil
}

public struct SubsonicAlbum: Equatable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artistId: String?
    public var year: Int?
    public var genre: String?
    public var coverArt: String? = nil
    public var songs: [SubsonicSong]
}

public struct SubsonicSong: Equatable {
    public var id: String
    public var title: String
    public var album: String?
    public var albumId: String?
    public var artist: String?
    public var artistId: String?
    public var track: Int?
    public var discNumber: Int?
    public var duration: Double?
    public var suffix: String?
    public var contentType: String?
    public var size: Int64?
    public var bitRate: Int?
    public var samplingRate: Int?
    public var coverArt: String? = nil
}

private final class XMLCollector: NSObject, XMLParserDelegate {
    public var sawResponse = false
    public var status: String?
    public var error: XMLErrorPayload?
    public var artists: [SubsonicArtist] = []
    public var artistDetail: SubsonicArtistDetail?
    public var albumSummaries: [SubsonicAlbumSummary] = []
    public var album: SubsonicAlbum?
    public var songs: [SubsonicSong] = []
    private var stack: [String] = []

    public func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "subsonic-response":
            sawResponse = true
            status = attributeDict["status"]
        case "error":
            error = XMLErrorPayload(
                code: Int(attributeDict["code"] ?? "") ?? 0,
                message: attributeDict["message"] ?? "Subsonic request failed"
            )
        case "artist":
            let id = attributeDict["id"] ?? ""
            let artist = SubsonicArtist(
                id: id,
                name: attributeDict["name"] ?? id,
                albumCount: Int(attributeDict["albumCount"] ?? "")
            )
            if stack.last == "subsonic-response" {
                artistDetail = SubsonicArtistDetail(id: artist.id, name: artist.name, albums: [])
            } else {
                artists.append(artist)
            }
        case "album":
            let summary = SubsonicAlbumSummary(
                id: attributeDict["id"] ?? "",
                name: attributeDict["name"] ?? attributeDict["id"] ?? "",
                artist: attributeDict["artist"],
                artistId: attributeDict["artistId"],
                songCount: Int(attributeDict["songCount"] ?? ""),
                year: Int(attributeDict["year"] ?? ""),
                genre: attributeDict["genre"],
                coverArt: attributeDict["coverArt"]
            )
            if stack.contains("artist") {
                albumSummaries.append(summary)
            } else {
                album = SubsonicAlbum(
                    id: summary.id,
                    name: summary.name,
                    artist: summary.artist,
                    artistId: summary.artistId,
                    year: summary.year,
                    genre: summary.genre,
                    coverArt: summary.coverArt,
                    songs: []
                )
            }
        case "song":
            songs.append(SubsonicSong(
                id: attributeDict["id"] ?? "",
                title: attributeDict["title"] ?? attributeDict["id"] ?? "",
                album: attributeDict["album"],
                albumId: attributeDict["albumId"],
                artist: attributeDict["artist"],
                artistId: attributeDict["artistId"],
                track: Int(attributeDict["track"] ?? ""),
                discNumber: Int(attributeDict["discNumber"] ?? ""),
                duration: Double(attributeDict["duration"] ?? ""),
                suffix: attributeDict["suffix"],
                contentType: attributeDict["contentType"],
                size: Int64(attributeDict["size"] ?? ""),
                bitRate: Int(attributeDict["bitRate"] ?? ""),
                samplingRate: Int(attributeDict["samplingRate"] ?? ""),
                coverArt: attributeDict["coverArt"]
            ))
        default:
            break
        }
        stack.append(elementName)
    }

    public func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if stack.last == elementName {
            stack.removeLast()
        }
    }
}

private struct XMLErrorPayload {
    public var code: Int
    public var message: String

    public var dictionary: [String: Any] {
        ["code": code, "message": message]
    }
}
