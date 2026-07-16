import Foundation

public enum CloudDriveAPI {
    public enum Provider: String, CaseIterable, Equatable {
        case dropbox
        case googleDrive
        case oneDrive
        case pCloud

        public init?(sourceKind: SourceKind) {
            switch sourceKind {
            case .dropbox: self = .dropbox
            case .googleDrive: self = .googleDrive
            case .oneDrive: self = .oneDrive
            case .pCloud: self = .pCloud
            default: return nil
            }
        }

        public var sourceKind: SourceKind {
            switch self {
            case .dropbox: return .dropbox
            case .googleDrive: return .googleDrive
            case .oneDrive: return .oneDrive
            case .pCloud: return .pCloud
            }
        }
    }

    public enum Endpoint: Equatable {
        case list(containerID: String?)
        case resolveFile(id: String, path: String?)
    }

    public enum Error: Swift.Error, Equatable {
        case malformedResponse
        case missingField(String)
        case unsupportedProvider
    }

    public static func request(provider: Provider,
                        endpoint: Endpoint,
                        accessToken: String) throws -> URLRequest {
        switch (provider, endpoint) {
        case (.dropbox, .list(let containerID)):
            var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "path": containerID ?? "",
                "recursive": false,
                "include_deleted": false,
            ])
            return request

        case (.dropbox, .resolveFile(let id, let path)):
            var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["path": path ?? id])
            return request

        case (.googleDrive, .list(let containerID)):
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            let parent = containerID ?? "root"
            components.queryItems = [
                URLQueryItem(name: "q", value: "'\(parent)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "files(id,name,mimeType,size,modifiedTime)"),
                URLQueryItem(name: "pageSize", value: "\(RemotePathPolicy.defaultPageCap)"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request

        case (.googleDrive, .resolveFile(let id, _)):
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(pathComponent(id))")!
            components.queryItems = [
                URLQueryItem(name: "alt", value: "media"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request

        case (.oneDrive, .list(let containerID)):
            let path = containerID.map { "items/\(pathComponent($0))/children" } ?? "root/children"
            var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(path)")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request

        case (.oneDrive, .resolveFile(let id, _)):
            var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(pathComponent(id))/content")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request

        case (.pCloud, .list(let containerID)):
            var components = URLComponents(string: "https://api.pcloud.com/listfolder")!
            let value = containerID ?? "/"
            let key = value.allSatisfy(\.isNumber) ? "folderid" : "path"
            components.queryItems = [URLQueryItem(name: key, value: value)]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request

        case (.pCloud, .resolveFile(let id, let path)):
            var components = URLComponents(string: "https://api.pcloud.com/getfilelink")!
            if let path {
                components.queryItems = [URLQueryItem(name: "path", value: path)]
            } else {
                components.queryItems = [URLQueryItem(name: "fileid", value: id)]
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    public static func decodeListing(provider: Provider, data: Data) throws -> [CloudDriveItem] {
        let object = try jsonObject(data)
        switch provider {
        case .dropbox:
            guard let dict = object as? [String: Any],
                  let entries = dict["entries"] as? [[String: Any]] else {
                throw Error.missingField("entries")
            }
            return try entries.map(decodeDropboxItem)
        case .googleDrive:
            guard let dict = object as? [String: Any],
                  let files = dict["files"] as? [[String: Any]] else {
                throw Error.missingField("files")
            }
            return try files.map(decodeGoogleItem)
        case .oneDrive:
            guard let dict = object as? [String: Any],
                  let values = dict["value"] as? [[String: Any]] else {
                throw Error.missingField("value")
            }
            return try values.map(decodeOneDriveItem)
        case .pCloud:
            guard let dict = object as? [String: Any],
                  int(dict["result"]) ?? 0 == 0,
                  let metadata = dict["metadata"] as? [String: Any],
                  let contents = metadata["contents"] as? [[String: Any]] else {
                throw Error.missingField("metadata.contents")
            }
            return try contents.map(decodePCloudItem)
        }
    }

    public static func decodeResolvedAsset(provider: Provider,
                                    data: Data,
                                    fallbackSize: Int64? = nil) throws -> ResolvedAsset {
        let object = try jsonObject(data)
        switch provider {
        case .dropbox:
            guard let dict = object as? [String: Any],
                  let link = string(dict["link"]),
                  let url = URL(string: link) else {
                throw Error.missingField("link")
            }
            let metadata = dict["metadata"] as? [String: Any]
            return ResolvedAsset(url: url, sizeBytes: int64(metadata?["size"]) ?? fallbackSize)
        case .pCloud:
            guard let dict = object as? [String: Any],
                  let hosts = dict["hosts"] as? [String],
                  let host = hosts.first,
                  let path = string(dict["path"]),
                  let url = URL(string: "https://\(host)\(path)") else {
                throw Error.missingField("hosts.path")
            }
            return ResolvedAsset(url: url, sizeBytes: fallbackSize)
        case .googleDrive, .oneDrive:
            throw Error.unsupportedProvider
        }
    }

    private static func decodeDropboxItem(_ dict: [String: Any]) throws -> CloudDriveItem {
        let tag = try requiredString(dict[".tag"], field: ".tag")
        let id = string(dict["id"]) ?? string(dict["path_lower"]) ?? string(dict["path_display"]) ?? UUID().uuidString
        let name = try requiredString(dict["name"], field: "name")
        let path = string(dict["path_lower"]) ?? string(dict["path_display"]) ?? id
        return CloudDriveItem(
            id: id,
            name: name,
            path: path,
            kind: tag == "folder" ? .folder : .file,
            sizeBytes: int64(dict["size"]),
            contentType: nil,
            temporaryURL: nil
        )
    }

    private static func decodeGoogleItem(_ dict: [String: Any]) throws -> CloudDriveItem {
        let id = try requiredString(dict["id"], field: "id")
        let name = try requiredString(dict["name"], field: "name")
        let mimeType = string(dict["mimeType"])
        return CloudDriveItem(
            id: id,
            name: name,
            path: id,
            kind: mimeType == "application/vnd.google-apps.folder" ? .folder : .file,
            sizeBytes: int64(dict["size"]),
            contentType: mimeType,
            temporaryURL: nil
        )
    }

    private static func decodeOneDriveItem(_ dict: [String: Any]) throws -> CloudDriveItem {
        let id = try requiredString(dict["id"], field: "id")
        let name = try requiredString(dict["name"], field: "name")
        let isFolder = dict["folder"] is [String: Any]
        let file = dict["file"] as? [String: Any]
        let downloadURL = string(dict["@microsoft.graph.downloadUrl"]).flatMap(URL.init(string:))
        return CloudDriveItem(
            id: id,
            name: name,
            path: id,
            kind: isFolder ? .folder : .file,
            sizeBytes: int64(dict["size"]),
            contentType: string(file?["mimeType"]),
            temporaryURL: downloadURL
        )
    }

    private static func decodePCloudItem(_ dict: [String: Any]) throws -> CloudDriveItem {
        let isFolder = bool(dict["isfolder"]) ?? false
        let id = isFolder
            ? string(dict["folderid"]) ?? string(dict["path"]) ?? UUID().uuidString
            : string(dict["fileid"]) ?? string(dict["path"]) ?? UUID().uuidString
        let name = try requiredString(dict["name"], field: "name")
        return CloudDriveItem(
            id: id,
            name: name,
            path: string(dict["path"]) ?? id,
            kind: isFolder ? .folder : .file,
            sizeBytes: int64(dict["size"]),
            contentType: string(dict["contenttype"]),
            temporaryURL: nil
        )
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Error.malformedResponse
        }
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let decoded = string(value), !decoded.isEmpty else {
            throw Error.missingField(field)
        }
        return decoded
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

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return Bool(string) }
        return nil
    }

    private static func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}

public struct CloudDriveItem: Equatable {
    public enum Kind: Equatable {
        case folder
        case file
    }

    public var id: String
    public var name: String
    public var path: String
    public var kind: Kind
    public var sizeBytes: Int64?
    public var contentType: String?
    public var temporaryURL: URL?

    public var isAudio: Bool {
        if let contentType, contentType.lowercased().hasPrefix("audio/") {
            return true
        }
        return RemotePathPolicy.acceptsAudioFile(path: name) || RemotePathPolicy.acceptsAudioFile(path: path)
    }
}
