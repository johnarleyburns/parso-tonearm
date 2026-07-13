import Foundation

struct IARemoteLibraryProvider: RemoteLibraryProvider {
    var preferFLAC: Bool = true

    var sourceKind: SourceKind { .iaItem }

    func browse(path raw: String) async throws -> [RemoteNode] {
        let preview = try await preview(from: raw)
        if let item = preview.resolvedItem {
            return item.tracks.map { track in
                RemoteNode(
                    id: track.remoteURL.absoluteString,
                    title: track.title,
                    path: track.remoteURL.absoluteString,
                    kind: .audio,
                    sizeBytes: track.sizeBytes,
                    durationSec: track.durationSec
                )
            }
        }
        return preview.members.map { member in
            RemoteNode(
                id: member.identifier,
                title: member.title ?? SourceService.prettify(member.identifier),
                path: member.identifier,
                kind: .item
            )
        }
    }

    func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard let url = URL(string: node.path), url.scheme != nil else {
            throw URLError(.badURL)
        }
        return ResolvedAsset(url: url, headers: [:], supportsByteRanges: true, sizeBytes: node.sizeBytes)
    }

    func refresh() async throws {}

    func preview(from raw: String) async throws -> SourcePreview {
        let parsed = try URLGrammar.parse(raw).get()
        switch parsed {
        case .item(let identifier, _):
            let item = try await ItemResolver(preferFLAC: preferFLAC).resolve(identifier: identifier)
            if item.mediatype == "collection" {
                return try await collectionPreview(identifier: identifier, title: item.title, raw: raw)
            }
            let permits = licensePermits(item.licenseText)
            return SourcePreview(
                kind: .iaItem, title: item.title,
                subtitle: "\(item.tracks.count) tracks · audio",
                licenseText: prettyLicense(item.licenseText),
                licensePermitsStreaming: permits,
                memberCount: item.tracks.count, totalCount: item.tracks.count,
                capHit: false, parsed: parsed, originalURL: raw,
                resolvedItem: item, members: [])

        case .collection(let identifier):
            return try await collectionPreview(identifier: identifier, title: nil, raw: raw)

        case .favorites(let screenname):
            let (members, total, capHit) = try await CollectionResolver().resolveFavorites(screenname: screenname)
            return SourcePreview(
                kind: .iaFavorites, title: "Favorites of @\(screenname)",
                subtitle: "\(members.count) items · audio",
                licenseText: nil, licensePermitsStreaming: true,
                memberCount: members.count, totalCount: total, capHit: capHit,
                parsed: parsed, originalURL: raw, resolvedItem: nil, members: members)

        case .list(let screenname, let listId, let slug):
            let members = try await ListResolver().resolve(screenname: screenname, listId: listId)
            let title = slug.map(SourceService.prettify) ?? "List by @\(screenname)"
            return SourcePreview(
                kind: .iaList, title: title,
                subtitle: "\(members.count) items · audio",
                licenseText: nil, licensePermitsStreaming: true,
                memberCount: members.count, totalCount: members.count, capHit: false,
                parsed: parsed, originalURL: raw, resolvedItem: nil, members: members)
        }
    }

    private func collectionPreview(identifier: String, title: String?, raw: String) async throws -> SourcePreview {
        let (members, total, capHit) = try await CollectionResolver().resolve(collection: identifier)
        let name = (title?.isEmpty == false) ? title! : SourceService.prettify(identifier)
        return SourcePreview(
            kind: .iaCollection, title: name,
            subtitle: "\(members.count) of \(total) items",
            licenseText: nil, licensePermitsStreaming: true,
            memberCount: members.count, totalCount: total, capHit: capHit,
            parsed: IAResolvedURL.collection(identifier: identifier),
            originalURL: raw, resolvedItem: nil, members: members)
    }

    private func licensePermits(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return true }
        return !text.contains("noderivatives") || true
    }

    private func prettyLicense(_ url: String?) -> String? {
        guard let url = url?.lowercased() else { return nil }
        if url.contains("publicdomain") || url.contains("cc0") { return "CC0 Public Domain" }
        if url.contains("by-sa") { return "CC BY-SA" }
        if url.contains("by-nc") { return "CC BY-NC" }
        if url.contains("by") { return "CC BY" }
        return "See license"
    }
}
