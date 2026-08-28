import Foundation

/// Resolves a spoken/typed playlist name (from a Siri or Shortcuts intent) to one of the
/// playlist titles actually downloaded on the watch. Pure and host-tested so the intent shell
/// stays trivial.
public enum WatchPlaylistNameMatch {
    /// Best case-insensitive match for `query` among `titles`, tried in order: exact, prefix,
    /// substring, then the reverse (a title contained in a wordier query). `nil` when nothing
    /// plausibly matches — the caller surfaces that as "no playlist matched".
    public static func best(_ query: String, in titles: [String]) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = titles.first(where: { $0.lowercased() == q }) { return exact }
        if let prefix = titles.first(where: { $0.lowercased().hasPrefix(q) }) { return prefix }
        if let contains = titles.first(where: { $0.lowercased().contains(q) }) { return contains }
        if let reverse = titles.first(where: { q.contains($0.lowercased()) }) { return reverse }
        return nil
    }
}
