import Foundation

public struct WebDAVDirectoryListing: Equatable {
    public var path: String
    public var entries: [WebDAVEntry]

    public var playableEntries: [WebDAVEntry] {
        entries.filter { entry in
            entry.kind == .directory || entry.isAudio
        }
    }
}

public struct WebDAVEntry: Identifiable, Equatable {
    public enum Kind: Equatable {
        case directory
        case file
    }

    public var id: String { href }
    public var href: String
    public var relativePath: String
    public var name: String
    public var kind: Kind
    public var contentLength: Int64?
    public var contentType: String?
    public var lastModified: String?

    public var isAudio: Bool {
        if let contentType, contentType.lowercased().hasPrefix("audio/") {
            return true
        }
        return RemotePathPolicy.acceptsAudioFile(path: relativePath)
    }
}

public enum WebDAVParser {
    public enum ParserError: Error, Equatable {
        case malformedXML
    }

    public static func parse(_ data: Data, basePath: String) throws -> WebDAVDirectoryListing {
        let collector = WebDAVXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw ParserError.malformedXML }

        let normalizedBase = normalizePath(basePath)
        let entries = collector.responses.compactMap { response -> WebDAVEntry? in
            guard response.isSuccessful else { return nil }
            let href = normalizePath(response.href)
            guard href != normalizedBase else { return nil }
            let relativePath = relativePath(for: href, basePath: normalizedBase)
            guard !relativePath.isEmpty else { return nil }
            let name = response.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WebDAVEntry(
                href: href,
                relativePath: relativePath,
                name: name?.isEmpty == false ? name! : lastPathComponent(relativePath),
                kind: response.isCollection ? .directory : .file,
                contentLength: response.contentLength,
                contentType: response.contentType,
                lastModified: response.lastModified
            )
        }
        return WebDAVDirectoryListing(path: normalizedBase, entries: entries)
    }

    private static func normalizePath(_ raw: String) -> String {
        let path: String
        if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
            path = url.path
        } else {
            path = raw
        }
        let decoded = path.removingPercentEncoding ?? path
        let collapsed = decoded.replacingOccurrences(of: #"//+"#, with: "/", options: .regularExpression)
        guard !collapsed.isEmpty else { return "/" }
        return collapsed.hasPrefix("/") ? collapsed : "/\(collapsed)"
    }

    private static func relativePath(for href: String, basePath: String) -> String {
        let base = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
        let relative: String
        if href.hasPrefix(base) {
            relative = String(href.dropFirst(base.count))
        } else {
            relative = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct WebDAVResponse {
    public var href = ""
    public var displayName: String?
    public var contentLength: Int64?
    public var contentType: String?
    public var lastModified: String?
    public var isCollection = false
    public var statuses: [String] = []

    public var isSuccessful: Bool {
        statuses.isEmpty || statuses.contains { $0.contains(" 200 ") || $0.hasSuffix(" 200 OK") }
    }
}

private final class WebDAVXMLCollector: NSObject, XMLParserDelegate {
    public var responses: [WebDAVResponse] = []
    private var current: WebDAVResponse?
    private var stack: [String] = []
    private var text = ""

    public func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        if name == "response" {
            current = WebDAVResponse()
        } else if name == "collection", stack.contains("resourcetype") {
            current?.isCollection = true
        }
        stack.append(name)
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            current?.href = value
        case "displayname":
            current?.displayName = value
        case "getcontentlength":
            current?.contentLength = Int64(value)
        case "getcontenttype":
            current?.contentType = value
        case "getlastmodified":
            current?.lastModified = value
        case "status":
            if !value.isEmpty { current?.statuses.append(value) }
        case "response":
            if let current { responses.append(current) }
            current = nil
        default:
            break
        }
        if stack.last == name {
            stack.removeLast()
        }
        text = ""
    }

    private func localName(_ elementName: String) -> String {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        return name.lowercased()
    }
}
