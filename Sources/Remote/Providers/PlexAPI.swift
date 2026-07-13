import Foundation

enum PlexAPI {
    static let defaultClient = Client(
        product: "Tonearm",
        version: "1.0",
        platform: "iOS",
        clientIdentifier: "tonearm-ios"
    )

    struct Client: Equatable {
        var product: String
        var version: String
        var platform: String
        var clientIdentifier: String
    }

    enum Endpoint: Equatable {
        case sections
        case artists(sectionKey: String)
        case children(ratingKey: String)
        case metadata(ratingKey: String)
    }

    enum Error: Swift.Error, Equatable {
        case invalidBaseURL
        case malformedResponse
        case missingField(String)
    }

    static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.invalidBaseURL }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
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

    static func request(baseURL rawBaseURL: URL,
                        endpoint: Endpoint,
                        token: String,
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
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(client.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(client.version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(client.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(client.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("1.0", forHTTPHeaderField: "X-Plex-Pms-Api-Version")
        return request
    }

    static func decodeSections(_ data: Data) throws -> [PlexItem] {
        try parse(data).items.filter { $0.kind == .section }
    }

    static func decodeItems(_ data: Data) throws -> [PlexItem] {
        try parse(data).items
    }

    static func decodeTrackMetadata(_ data: Data) throws -> PlexItem {
        guard let track = try parse(data).items.first(where: { $0.kind == .track }) else {
            throw Error.missingField("Track")
        }
        guard track.partKey?.isEmpty == false else {
            throw Error.missingField("Track.Part.key")
        }
        return track
    }

    private static func endpointURL(baseURL: URL, endpoint: Endpoint) -> URL {
        switch endpoint {
        case .sections:
            return baseURL
                .appendingPathComponent("library", isDirectory: true)
                .appendingPathComponent("sections")
        case .artists(let sectionKey):
            return baseURL
                .appendingPathComponent("library", isDirectory: true)
                .appendingPathComponent("sections", isDirectory: true)
                .appendingPathComponent(sectionKey, isDirectory: true)
                .appendingPathComponent("all")
        case .children(let ratingKey):
            return baseURL
                .appendingPathComponent("library", isDirectory: true)
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent(ratingKey, isDirectory: true)
                .appendingPathComponent("children")
        case .metadata(let ratingKey):
            return baseURL
                .appendingPathComponent("library", isDirectory: true)
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent(ratingKey)
        }
    }

    private static func queryItems(for endpoint: Endpoint) -> [URLQueryItem]? {
        switch endpoint {
        case .artists:
            return [
                URLQueryItem(name: "type", value: "8"),
                URLQueryItem(name: "includeFields", value: "title,type,ratingKey,key"),
            ]
        case .sections, .children, .metadata:
            return nil
        }
    }

    private static func parse(_ data: Data) throws -> PlexMediaContainer {
        let collector = PlexXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), collector.sawMediaContainer else { throw Error.malformedResponse }
        return PlexMediaContainer(items: collector.items)
    }
}

struct PlexMediaContainer: Equatable {
    var items: [PlexItem]
}

struct PlexItem: Equatable {
    enum Kind: Equatable {
        case section
        case artist
        case album
        case track
        case unknown(String)
    }

    var ratingKey: String?
    var key: String?
    var title: String
    var kind: Kind
    var durationSec: Double?
    var sizeBytes: Int64?
    var partKey: String?

    var isMusicSection: Bool {
        kind == .section
    }
}

private final class PlexXMLCollector: NSObject, XMLParserDelegate {
    var sawMediaContainer = false
    var items: [PlexItem] = []
    private var currentTrack: PlexItem?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "MediaContainer":
            sawMediaContainer = true
        case "Directory":
            items.append(Self.item(from: attributeDict, elementName: elementName))
        case "Track":
            currentTrack = Self.item(from: attributeDict, elementName: elementName)
        case "Part":
            guard currentTrack != nil else { return }
            if currentTrack?.partKey == nil {
                currentTrack?.partKey = attributeDict["key"]
            }
            if currentTrack?.sizeBytes == nil {
                currentTrack?.sizeBytes = attributeDict["size"].flatMap(Int64.init)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "Track", let track = currentTrack {
            items.append(track)
            currentTrack = nil
        }
    }

    private static func item(from attributes: [String: String], elementName: String) -> PlexItem {
        let type = attributes["type"]
        let kind: PlexItem.Kind
        if elementName == "Track" || type == "track" {
            kind = .track
        } else if type == "artist" {
            kind = attributes["ratingKey"] == nil ? .section : .artist
        } else if type == "album" {
            kind = .album
        } else {
            kind = .unknown(type ?? elementName)
        }
        return PlexItem(
            ratingKey: attributes["ratingKey"],
            key: attributes["key"],
            title: attributes["title"] ?? attributes["titleSort"] ?? attributes["key"] ?? "",
            kind: kind,
            durationSec: attributes["duration"].flatMap(Double.init).map { $0 / 1000 },
            sizeBytes: attributes["size"].flatMap(Int64.init),
            partKey: nil
        )
    }
}
