import Foundation

/// Chooses a genuine cover image from an IA item's files list, distinguishing a
/// real album cover from IA's auto-generated waveform/spectrogram/thumbnail art.
///
/// The IA `metadata` files array is authoritative: a real cover is either
/// designated (`format: "Item Image"`), conventionally named (`cover.jpg`), or
/// an `original` image; auto-generated waveform/spectrogram derivatives and the
/// `__ia_thumb.jpg` colored-waveform thumbnail are rejected unless the thumbnail
/// is the item's only (genuine, embedded) art.
public enum IACoverPicker {

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "tif", "tiff", "jp2"
    ]

    private static let coverKeywords: Set<String> = [
        "cover", "folder", "front", "albumart"
    ]

    /// Format/name fragments that mark IA-generated, non-cover art.
    private static let generatedFragments = [
        "thumb", "tile", "spectrogram", "waveform", "columbia peaks", "animated"
    ]

    private static let iaThumbName = "__ia_thumb.jpg"

    /// Returns the filename of the best genuine cover image, or nil if the item
    /// only has auto-generated waveform/spectrogram/thumbnail art.
    public static func pickCoverFilename(files: [IAFile]) -> String? {
        let images = files.filter(isImage)

        // 1. IA's designated cover.
        if let itemImage = images.first(where: { ($0.format ?? "").lowercased() == "item image" }) {
            return itemImage.name
        }

        // 2. Conventionally named cover (cover/folder/front/albumart).
        if let named = images.first(where: { hasCoverName($0.name) }) {
            return named.name
        }

        // 3. An original image that isn't the thumbnail or a generated derivative.
        if let original = images.first(where: {
            ($0.source ?? "").lowercased() == "original"
                && !isThumb($0.name)
                && !isGenerated($0)
        }) {
            return original.name
        }

        // 4. Last resort: the item thumbnail, only if it's genuine embedded art
        //    (no waveform/spectrogram derivatives were generated for this item).
        if let thumb = images.first(where: { isThumb($0.name) }),
           !files.contains(where: hasGeneratedWaveform) {
            return thumb.name
        }

        return nil
    }

    // MARK: - Helpers

    private static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private static func isImage(_ f: IAFile) -> Bool {
        imageExtensions.contains(ext(f.name))
    }

    private static func isThumb(_ name: String) -> Bool {
        (name as NSString).lastPathComponent.lowercased() == iaThumbName
    }

    private static func hasCoverName(_ name: String) -> Bool {
        let stem = ((name as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
        if coverKeywords.contains(stem) { return true }
        let tokens = stem.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains { coverKeywords.contains($0) }
    }

    private static func isGenerated(_ f: IAFile) -> Bool {
        let fmt = (f.format ?? "").lowercased()
        if generatedFragments.contains(where: { fmt.contains($0) }) { return true }
        let name = f.name.lowercased()
        return name.contains("spectrogram") || name.contains("waveform")
    }

    private static func hasGeneratedWaveform(_ f: IAFile) -> Bool {
        let fmt = (f.format ?? "").lowercased()
        let name = f.name.lowercased()
        return fmt.contains("spectrogram") || fmt.contains("waveform")
            || name.contains("spectrogram") || name.contains("waveform")
    }
}
