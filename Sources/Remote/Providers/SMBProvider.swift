import Foundation

struct SMBFolderPolicy {
    static func displayName(rootURL: URL) -> String {
        let name = rootURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "SMB Library" : name
    }

    static func credentialAccount(sourceID: Int64) -> String {
        "smb:\(sourceID)"
    }
}

/// SMB access is mediated by iOS Files. Users connect an SMB server in Files and
/// grant Tonearm a security-scoped folder bookmark; the provider then browses the
/// folder tree like any other remote library without importing or copying audio.
struct SMBProvider: RemoteLibraryProvider {
    var rootBookmark: Data
    var fileManager: FileManager = .default

    var sourceKind: SourceKind { .smb }

    func browse(path rawPath: String) async throws -> [RemoteNode] {
        let path = try RemotePathPolicy.normalize(rawPath)
        return try withRootAccess { root in
            let folder = url(for: path.segments, under: root)
            let urls = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let nodes = try urls.compactMap { url -> RemoteNode? in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let relative = relativePath(for: url, root: root)
                if values.isDirectory == true {
                    return RemoteNode(
                        id: "folder:\(relative)",
                        title: url.lastPathComponent,
                        path: relative,
                        kind: .directory
                    )
                }
                guard RemotePathPolicy.acceptsAudioFile(path: url.path) else { return nil }
                return RemoteNode(
                    id: "file:\(relative)",
                    title: url.lastPathComponent,
                    path: relative,
                    kind: .audio,
                    sizeBytes: values.fileSize.map(Int64.init)
                )
            }
            return nodes.sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .directory }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard node.kind == .audio else { throw URLError(.badURL) }
        let path = try RemotePathPolicy.normalize(node.path)
        return try withRootAccess { root in
            ResolvedAsset(
                url: url(for: path.segments, under: root),
                headers: [:],
                supportsByteRanges: false,
                sizeBytes: node.sizeBytes
            )
        }
    }

    func refresh() async throws {
        _ = try await browse(path: "")
    }

    static func from(source: Source,
                     credentialStore: CredentialStore = CredentialStore()) throws -> SMBProvider {
        guard source.kind == .smb,
              let sourceID = source.id,
              let data = try credentialStore.read(
                account: SMBFolderPolicy.credentialAccount(sourceID: sourceID)
              ) else {
            throw URLError(.userAuthenticationRequired)
        }
        return SMBProvider(rootBookmark: data)
    }

    private func withRootAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let result = try BookmarkVault.withAccess(rootBookmark, body) else {
            throw URLError(.userAuthenticationRequired)
        }
        return result
    }

    private func url(for segments: [String], under root: URL) -> URL {
        segments.reduce(root) { partial, segment in
            partial.appendingPathComponent(segment)
        }
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(itemPath.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
