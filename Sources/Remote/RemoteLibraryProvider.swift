import Foundation

struct RemoteNode: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case directory
        case audio
        case item
        case collection
    }

    var id: String
    var title: String
    var path: String
    var kind: Kind
    var sizeBytes: Int64?
    var durationSec: Double?

    init(id: String,
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

struct ResolvedAsset: Codable, Equatable {
    var url: URL
    var headers: [String: String]
    var supportsByteRanges: Bool
    var sizeBytes: Int64?

    init(url: URL,
         headers: [String: String] = [:],
         supportsByteRanges: Bool = true,
         sizeBytes: Int64? = nil) {
        self.url = url
        self.headers = headers
        self.supportsByteRanges = supportsByteRanges
        self.sizeBytes = sizeBytes
    }
}

protocol RemoteLibraryProvider {
    var sourceKind: SourceKind { get }

    func browse(path: String) async throws -> [RemoteNode]
    func resolve(node: RemoteNode) async throws -> ResolvedAsset
    func refresh() async throws
}
