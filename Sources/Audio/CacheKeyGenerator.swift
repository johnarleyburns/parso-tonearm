import Foundation
import CryptoKit

public enum CacheKeyGenerator {
    public static let scheme = "tonearm-cache"

    public static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return hex + "-" + (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    public static func cacheURL(for remote: URL) -> URL {
        var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
        comps.scheme = scheme
        return comps.url ?? remote
    }
}
