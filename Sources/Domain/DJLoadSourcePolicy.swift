import Foundation

/// Decides whether DJ preparation may use a security-scoped bookmark or must
/// use the URL already verified by the playable-asset resolver.
public enum DJLoadSourcePolicy {
    public static func shouldUseBookmark(bookmarkURL: URL?, sourceURL: URL) -> Bool {
        guard let bookmarkURL, bookmarkURL.isFileURL, sourceURL.isFileURL else { return false }
        return bookmarkURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }
}
