import Foundation

public struct RemoteNode: Identifiable, Codable, Equatable, Hashable {
    public enum Kind: String, Codable {
        case directory
        case audio
        case item
        case collection
    }

    public var id: String
    public var title: String
    public var path: String
    public var kind: Kind
    public var sizeBytes: Int64?
    public var durationSec: Double?

    public init(id: String,
         title: String,
         path: String,
         kind: Kind,
         sizeBytes: Int64? = nil,
         durationSec: Double? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.durationSec = durationSec
    }
}

public struct ResolvedAsset: Codable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public var supportsByteRanges: Bool
    public var sizeBytes: Int64?

    public init(url: URL,
         headers: [String: String] = [:],
         supportsByteRanges: Bool = true,
         sizeBytes: Int64? = nil) {
        self.url = url
        self.headers = headers
        self.supportsByteRanges = supportsByteRanges
        self.sizeBytes = sizeBytes
    }
}

public protocol RemoteLibraryProvider {
    var sourceKind: SourceKind { get }

    func browse(path: String) async throws -> [RemoteNode]
    func resolve(node: RemoteNode) async throws -> ResolvedAsset
    func refresh() async throws
}
