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
        if let first = bytes.first, first == 0x7B || first == 0x5B || first == 0x3C { return false } // { [ <
        return true
    }
}
