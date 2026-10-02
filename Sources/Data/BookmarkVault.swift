import Foundation

public enum BookmarkVault {
    /// On macOS a sandboxed app only keeps access to a user-picked or dropped
    /// file across launches through an app-scoped *security-scoped* bookmark
    /// (`com.apple.security.files.bookmarks.app-scope`); iOS bookmarks carry
    /// that access implicitly. A creation that cannot be security-scoped
    /// (e.g. an unsandboxed host-test process) falls back to the plain form.
    public static func makeBookmark(for url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope],
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil) {
            return scoped
        }
        #endif
        return try? url.bookmarkData(options: [.minimalBookmark],
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
    }

    public static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        #endif
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
