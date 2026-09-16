import UIKit
import CoreImage

/// "Phase 2" fallback artwork for a track with no real cover: a bundled
/// stock photo whose subject matches a word in the track's title, duotone-
/// tinted with the exact same two colors `ArtworkView`'s plain gradient
/// fallback already derives for that track (see `ArtworkView.colorIdentity`)
/// — a strict visual upgrade over the flat gradient, never a different
/// palette. Every bundled image is confirmed Public Domain or CC0 from
/// Wikimedia Commons: bundling anything requiring attribution (CC-BY/
/// CC-BY-SA) into the app binary is a real, documented legal gray area for
/// App Store distribution, so this library deliberately never sources those
/// (researched this session — see `docs/plans/` if this grows further).
enum KeywordArtworkLibrary {
    /// Bundled JPEG filenames under `Resources/ArtworkKeywords/` (also the
    /// matchable keyword itself). Deliberately small and hand-picked rather
    /// than an automated 100+-word scrape — every entry here has a real,
    /// specifically-verified CC0/PD source. Expected to grow over time.
    static let keywords: Set<String> = ["love", "night", "dream", "rain", "heart", "blue"]

    private static let stopwords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "but", "in", "on", "at", "to", "for",
        "with", "by", "from", "up", "down", "over", "under", "into", "onto",
        "is", "are", "was", "were", "be", "been", "being", "it", "its", "this",
        "that", "these", "those", "my", "your", "our", "their", "his", "her",
        "feat", "ft", "featuring", "remix", "mix", "edit", "version", "live",
        "pt", "part", "vol", "no",
    ]

    /// Not a real stemmer — just enough to catch "golden"->"gold",
    /// "nights"->"night", "dreaming"->"dream". Titles are short and the
    /// keyword library is small and curated, so a full Porter/Snowball
    /// stemmer would be overkill on-device for what this buys.
    private static let suffixRules: [(suffix: String, replacement: String)] = [
        ("en", ""), ("s", ""), ("ing", ""), ("ed", ""),
    ]

    /// Finds the first (leftmost) title word that matches a bundled keyword,
    /// after stripping stopwords/short words and normalizing common
    /// suffixes, falling back to a deterministic (title-hash) pick from the
    /// same bundled library when nothing matches. No ML/embeddings —
    /// deliberately the simplest thing that works. Real report after the
    /// keyword set shipped: "I have 'night' matching but not 'morning', I
    /// end up having very little artwork especially when my track names are
    /// things like 'looperman' — just randomly assign generic artwork based
    /// on a hash of the title if you don't match any words." A small, fully
    /// curated keyword library will never cover most real titles by direct
    /// match alone, so the hash fallback is what makes every track land on
    /// a real bundled photo instead of the plain gradient, while a genuine
    /// word match still wins whenever one exists (a title that says "Rainy
    /// Night" should show rain/night art, not an arbitrary pick).
    static func match(title: String) -> String? {
        let words = title
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0.lowercased()) }
        for word in words {
            for candidate in normalizedForms(of: word.lowercased()) where keywords.contains(candidate) {
                return candidate
            }
        }
        guard !sortedKeywords.isEmpty else { return nil }
        let index = Int(stableHash(title) % UInt64(sortedKeywords.count))
        return sortedKeywords[index]
    }

    /// A fixed iteration order for the hash fallback above — `Set` iteration
    /// order is not guaranteed stable (Swift's `Hasher` is randomized per
    /// process launch), which would have made the fallback pick shift
    /// between app launches for the exact same track, defeating the point
    /// of a stable per-track identity.
    private static let sortedKeywords: [String] = keywords.sorted()

    /// FNV-1a over UTF-8 bytes — deterministic across launches/devices,
    /// unlike Swift's `Hasher` (same reasoning as `ArtworkView.stableHash`,
    /// duplicated here rather than shared: it's six lines and these two
    /// types are in different files with no other coupling).
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private static func normalizedForms(of word: String) -> [String] {
        var forms = [word]
        for rule in suffixRules where word.hasSuffix(rule.suffix) && word.count - rule.suffix.count >= 3 {
            forms.append(String(word.dropLast(rule.suffix.count)) + rule.replacement)
        }
        return forms
    }

    /// Loaded once per keyword and kept for the process lifetime — six to a
    /// few dozen small bundled JPEGs, trivial to hold entirely in memory
    /// rather than re-reading from disk on every match. `@MainActor`-isolated
    /// (not a separate actor): every caller is `ArtworkView`'s `.task`, which
    /// already runs on the main actor as a SwiftUI view — isolating here
    /// instead of introducing a cross-actor `UIImage` hop keeps this simple.
    @MainActor private static var imageCache: [String: UIImage] = [:]

    @MainActor static func image(forKeyword keyword: String) -> UIImage? {
        if let cached = imageCache[keyword] { return cached }
        // Try a preserved "ArtworkKeywords" subdirectory first (folder
        // reference), then a flat lookup (group reference flattens at build
        // time) — xcodegen's exact bundling behavior for a plain folder
        // path isn't asserted elsewhere in this codebase, so support both
        // rather than gamble on one.
        let url = Bundle.main.url(forResource: keyword, withExtension: "jpg", subdirectory: "ArtworkKeywords")
            ?? Bundle.main.url(forResource: keyword, withExtension: "jpg")
        guard let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        imageCache[keyword] = image
        return image
    }

    /// Duotone rendering (`CIContext` + a filter pass) isn't free — cache
    /// the tinted result per (keyword, color) combination so the SAME
    /// track showing up in multiple lists/re-appearing in one scroll
    /// session never re-renders it, same performance discipline as
    /// `ArtworkService`'s other caches.
    @MainActor private static var tintedCache: [String: UIImage] = [:]

    @MainActor static func tintedImage(forKeyword keyword: String, dark: UIColor, base: UIColor) -> UIImage? {
        let key = "\(keyword)-\(dark.tonearmHex)-\(base.tonearmHex)"
        if let cached = tintedCache[key] { return cached }
        guard let source = image(forKeyword: keyword), let tinted = source.duotone(dark: dark, base: base)
        else { return nil }
        tintedCache[key] = tinted
        return tinted
    }
}

private extension UIColor {
    /// A stable cache-key component — exact color equality isn't needed,
    /// just a value that changes whenever the color meaningfully does.
    var tonearmHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

extension UIImage {
    /// Duotone remap: shadows -> `dark`, highlights -> `base` — the same two
    /// colors a plain gradient fallback would have used, now mapped by the
    /// bundled photo's own luminance via CoreImage's `CIFalseColor` (a
    /// hardware-accelerated, well-tested system filter; no manual per-pixel
    /// loop). Returns `nil` (never a partially-processed or wrong-color
    /// image) if the filter pipeline fails for any reason.
    func duotone(dark: UIColor, base: UIColor) -> UIImage? {
        guard let ciImage = CIImage(image: self),
              let filter = CIFilter(name: "CIFalseColor")
        else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: dark), forKey: "inputColor0")
        filter.setValue(CIColor(color: base), forKey: "inputColor1")
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
