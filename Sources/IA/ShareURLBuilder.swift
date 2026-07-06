import Foundation

enum ShareURLBuilder {
    static func url(identifier: String) -> URL? {
        guard !identifier.isEmpty else { return nil }
        let cleanId = identifier.hasPrefix("fav-") ? String(identifier.dropFirst(4)) : identifier
        return URL(string: "https://archive.org/details/\(cleanId)")
    }
}
