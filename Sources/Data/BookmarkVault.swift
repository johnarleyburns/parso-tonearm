import Foundation

public enum BookmarkVault {
    /// iOS bookmarks carry access to a user-picked or dropped file across
    /// launches implicitly — no app-scoped security-scope bookmark option
    /// like a sandboxed macOS app needs.
    public static func makeBookmark(for url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: [.minimalBookmark],
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
    }

    public static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    public static func withAccess<T>(_ data: Data, _ body: (URL) throws -> T) rethrows -> T? {
        guard let (url, _) = resolve(data) else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
