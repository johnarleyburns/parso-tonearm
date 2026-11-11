import Foundation

/// Sniffs a cached blob's leading bytes to tell real audio from an HTTP error body (an HTML or
/// JSON error page) that got written and adopted as a "complete" download before the HTTP-status
/// check in `AppState.cacheCompletedDownload` existed. Deliberately conservative: a format this
/// doesn't recognize is still reported as audio (`true`) — it is not an exhaustive decoder, only a
/// cheap way to catch the specific poisoning shape this bug produced (an error page saved as
/// bytes), not a general media validator.
public enum AudioFileSniffer {
    /// `prefix` should be at least the first 16 bytes of the file; fewer bytes than that are
    /// treated as inconclusive (`true`) rather than flagged.
    public static func looksLikeAudio(prefix: Data) -> Bool {
        guard prefix.count >= 4 else { return true }
        let bytes = [UInt8](prefix)

        if bytes.starts(with: [0x49, 0x44, 0x33]) { return true }                  // "ID3" (MP3 w/ ID3v2 tag)
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return true }            // "fLaC"
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return true }            // "OggS"
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return true }            // "RIFF" (WAV)
        if bytes.starts(with: [0x46, 0x4F, 0x52, 0x4D]) { return true }            // "FORM" (AIFF)
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return true }             // bare MPEG frame sync
        if bytes.count >= 8, bytes[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) { return true } // "ftyp" (MP4/M4A)

        // The specific poisoning shape this is for: an HTTP error body (JSON or HTML) saved as if
        // it were the audio file.
        if let first = bytes.first, first == 0x7B || first == 0x5B || first == 0x3C { return false } // JSON object/array, or HTML
        return true
    }

    /// Best-effort MIME type from a blob's leading bytes, used as the AVFoundation format hint for
    /// an extensionless cache blob whose URL/provider gave no type. `nil` when unrecognized.
    public static func mimeType(prefix: Data) -> String? {
        let bytes = [UInt8](prefix)
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x49, 0x44, 0x33]) { return "audio/mpeg" }
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "audio/flac" }
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return "audio/ogg" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "audio/wav" }
        if bytes.starts(with: [0x46, 0x4F, 0x52, 0x4D]) { return "audio/aiff" }
        if bytes.count >= 8, bytes[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) { return "audio/mp4" }
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return "audio/mpeg" }
        return nil
    }

    /// Leading bytes of `url` (up to 64), or `nil` if unreadable.
    public static func readPrefix(of url: URL) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: 64)
    }
}
