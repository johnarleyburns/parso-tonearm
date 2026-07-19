import Foundation

public enum JellyfinAPI {
    public static let defaultClient = Client(
        name: "Tonearm",
        device: "iPhone",
        deviceID: "tonearm-ios",
        version: "1.0"
    )

    public struct Client: Equatable {
        var name: String
        var device: String
        var deviceID: String
        var version: String
    }

    public enum Endpoint: Equatable {
        case authenticate(username: String, password: String)
        case albumArtists(userID: String)
        case albums(userID: String, artistID: String)
        case albumSongs(userID: String, albumID: String)
        case stream(itemID: String)

        var method: String {
            switch self {
            case .authenticate:
                return "POST"
            case .albumArtists, .albums, .albumSongs, .stream:
                return "GET"
            }
        }
    }

    public enum Error: Swift.Error, Equatable {
        case invalidBaseURL
        case malformedResponse
        case missingField(String)
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

    public static func authorizationHeader(client: Client = defaultClient, token: String? = nil) -> String {
        var parts = [
            #"MediaBrowser Client="\#(headerEscaped(client.name))""#,
            #"Device="\#(headerEscaped(client.device))""#,
            #"DeviceId="\#(headerEscaped(client.deviceID))""#,
            #"Version="\#(headerEscaped(client.version))""#,
        ]
        if let token, !token.isEmpty {
            parts.append(#"Token="\#(headerEscaped(token))""#)
        }
        return parts.joined(separator: ", ")
    }

    public static func request(baseURL rawBaseURL: URL,
                        endpoint: Endpoint,
                        token: String? = nil,
                        client: Client = defaultClient) throws -> URLRequest {
        let baseURL = try normalizeBaseURL(rawBaseURL.absoluteString)
        guard var components = URLComponents(
            url: endpointURL(baseURL: baseURL, endpoint: endpoint),
            resolvingAgainstBaseURL: false
        ) else {
            throw Error.invalidBaseURL
        }
        components.queryItems = queryItems(for: endpoint)
        guard let url = components.url else { throw Error.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader(client: client, token: token), forHTTPHeaderField: "X-Emby-Authorization")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if case .authenticate(let username, let password) = endpoint {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "Username": username,
                "Pw": password,
            ])
        }
        return request
    }

    public static func decodeAuthentication(_ data: Data) throws -> JellyfinAuthentication {
        guard let object = try jsonObject(data) as? [String: Any] else {
            throw Error.malformedResponse
        }
        let token = try requiredString(object["AccessToken"], field: "AccessToken")
        let serverID = string(object["ServerId"])
        guard let user = object["User"] as? [String: Any] else {
            throw Error.missingField("User")
        }
        let userID = try requiredString(user["Id"], field: "User.Id")
        let username = string(user["Name"])
        return JellyfinAuthentication(accessToken: token, userID: userID, username: username, serverID: serverID)
    }

    public static func decodeItems(_ data: Data) throws -> JellyfinItemPage {
        guard let object = try jsonObject(data) as? [String: Any] else {
            throw Error.malformedResponse
        }
        guard let rawItems = object["Items"] as? [[String: Any]] else {
            throw Error.missingField("Items")
        }
        let items = try rawItems.map(decodeItem)
        return JellyfinItemPage(
            items: items,
            totalRecordCount: int(object["TotalRecordCount"]) ?? items.count,
            startIndex: int(object["StartIndex"]) ?? 0
        )
    }

    private static func endpointURL(baseURL: URL, endpoint: Endpoint) -> URL {
        switch endpoint {
        case .authenticate:
            return baseURL
                .appendingPathComponent("Users", isDirectory: true)
                .appendingPathComponent("AuthenticateByName")
        case .albumArtists:
            return baseURL
                .appendingPathComponent("Artists", isDirectory: true)
                .appendingPathComponent("AlbumArtists")
        case .albums(let userID, _), .albumSongs(let userID, _):
            return baseURL
                .appendingPathComponent("Users", isDirectory: true)
                .appendingPathComponent(userID, isDirectory: true)
                .appendingPathComponent("Items")
        case .stream(let itemID):
            return baseURL
                .appendingPathComponent("Audio", isDirectory: true)
                .appendingPathComponent(itemID, isDirectory: true)
                .appendingPathComponent("stream")
        }
    }

    private static func queryItems(for endpoint: Endpoint) -> [URLQueryItem]? {
        switch endpoint {
        case .authenticate, .stream:
            return nil
        case .albumArtists(let userID):
            return [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]
        case .albums(_, let artistID):
            return [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "AlbumArtistIds", value: artistID),
                URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "Genres,DateCreated,MediaSources,ImageTags"),
            ]
        case .albumSongs(_, let albumID):
            return [
                URLQueryItem(name: "ParentId", value: albumID),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "MediaSources,Genres,AudioInfo,ImageTags"),
            ]
        }
    }

    public static func imageURL(baseURL rawBaseURL: URL, itemID: String, tag: String?) throws -> URL {
        let baseURL = try normalizeBaseURL(rawBaseURL.absoluteString)
        guard var components = URLComponents(
            url: baseURL
                .appendingPathComponent("Items", isDirectory: true)
                .appendingPathComponent(itemID, isDirectory: true)
                .appendingPathComponent("Images", isDirectory: true)
                .appendingPathComponent("Primary"),
            resolvingAgainstBaseURL: false
        ) else {
            throw Error.invalidBaseURL
        }
        if let tag, !tag.isEmpty {
            components.queryItems = [URLQueryItem(name: "tag", value: tag)]
        }
        guard let url = components.url else { throw Error.invalidBaseURL }
        return url
    }

    private static func decodeItem(_ dict: [String: Any]) throws -> JellyfinItem {
        let id = try requiredString(dict["Id"], field: "Item.Id")
        let name = string(dict["Name"]) ?? id
        let mediaSources = (dict["MediaSources"] as? [[String: Any]]) ?? []
        let primarySource = mediaSources.first ?? [:]
        let audioStream = mediaSources.lazy
            .flatMap { ($0["MediaStreams"] as? [[String: Any]]) ?? [] }
            .first { string($0["Type"]) == "Audio" || string($0["Type"]) == nil }
        let imageTags = dict["ImageTags"] as? [String: Any]
        return JellyfinItem(
            id: id,
            name: name,
            type: itemType(string(dict["Type"])),
            albumID: string(dict["AlbumId"]),
            album: string(dict["Album"]),
            albumArtist: string(dict["AlbumArtist"]),
            artists: strings(dict["Artists"]),
            productionYear: int(dict["ProductionYear"]),
            indexNumber: int(dict["IndexNumber"]),
            parentIndexNumber: int(dict["ParentIndexNumber"]),
            durationSec: durationSeconds(dict["RunTimeTicks"]) ?? mediaSources.compactMap { durationSeconds($0["RunTimeTicks"]) }.first,
            sizeBytes: int64(dict["Size"]) ?? mediaSources.compactMap { int64($0["Size"]) }.first,
            container: string(dict["Container"]) ?? mediaSources.compactMap { string($0["Container"]) }.first,
            codec: string(audioStream?["Codec"]) ?? string(primarySource["Container"]) ?? string(dict["Container"]),
            sampleRate: int(audioStream?["SampleRate"]),
            bitRate: int(audioStream?["BitRate"]),
            primaryImageTag: string(imageTags?["Primary"]),
            albumPrimaryImageTag: string(dict["AlbumPrimaryImageTag"])
        )
    }

    private static func itemType(_ raw: String?) -> JellyfinItem.ItemType {
        switch raw {
        case "MusicArtist", "Artist":
            return .artist
        case "MusicAlbum", "Album":
            return .album
        case "Audio":
            return .audio
        case "Folder", "CollectionFolder":
            return .folder
        default:
            return .unknown(raw ?? "")
        }
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let decoded = string(value), !decoded.isEmpty else {
            throw Error.missingField(field)
        }
        return decoded
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Error.malformedResponse
        }
    }

    private static func headerEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func strings(_ value: Any?) -> [String] {
        if let strings = value as? [String] { return strings }
        if let string = value as? String { return [string] }
        return []
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
        if let int64 = value as? Int64 { return int64 }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func durationSeconds(_ value: Any?) -> Double? {
        guard let ticks = int64(value), ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
    }
}

public struct JellyfinAuthentication: Equatable {
    public var accessToken: String
    public var userID: String
    public var username: String?
    public var serverID: String?
}

public struct JellyfinItemPage: Equatable {
    public var items: [JellyfinItem]
    public var totalRecordCount: Int
    public var startIndex: Int
}

public struct JellyfinItem: Equatable {
    public enum ItemType: Equatable {
        case artist
        case album
        case audio
        case folder
        case unknown(String)
    }

    public var id: String
    public var name: String
    public var type: ItemType
    public var albumID: String? = nil
    public var album: String?
    public var albumArtist: String?
    public var artists: [String]
    public var productionYear: Int?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var durationSec: Double?
    public var sizeBytes: Int64?
    public var container: String?
    public var codec: String? = nil
    public var sampleRate: Int? = nil
    public var bitRate: Int? = nil
    public var primaryImageTag: String? = nil
    public var albumPrimaryImageTag: String? = nil
}
