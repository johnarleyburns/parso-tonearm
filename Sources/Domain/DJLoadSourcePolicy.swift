import Foundation

/// Decides whether DJ preparation may use a security-scoped bookmark or must
/// use the URL already verified by the playable-asset resolver.
public enum DJLoadSourcePolicy {
    public static func shouldUseBookmark(bookmarkURL: URL?, sourceURL: URL) -> Bool {
        guard let bookmarkURL, bookmarkURL.isFileURL, sourceURL.isFileURL else { return false }
        return bookmarkURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }

    /// Remote cache blobs are extensionless, so retain the original asset's
    /// codec or URL/query hint before the cache URL is handed to the decoder.
    public static func containerHint(codec: String?, sourceURL: URL,
                                     originalURL: URL? = nil) -> String? {
        let candidates = [codec, originalURL?.absoluteString, sourceURL.absoluteString]
            .compactMap { $0?.lowercased() }
        for value in candidates {
            if value.contains("flac") { return "flac" }
            if value.contains("opus") { return "opus" }
            if value.contains("ogg") { return "ogg" }
            if value.contains("mp3") || value.contains("mpeg") || value.contains("mp32") { return "mp3" }
            if value.contains("m4b") { return "m4b" }
            if value.contains("m4a") || value.contains("alac") || value.contains("mp4") { return "m4a" }
            if value.contains("aiff") || value.hasSuffix(".aif") { return "aiff" }
            if value.contains("caf") { return "caf" }
            if value.contains("wav") || value.contains("wave") { return "wav" }
            if value.contains("aac") { return "aac" }
        }
        return nil
    }
}

public enum DJLoadFailureStage: String, Sendable, Equatable {
    case loadRecord = "load record"
    case resolveSource = "resolve source"
    case decodeAndAnalyze = "decode/analyze"
    case loadEngine = "load audio engine"
    case persistAnalysis = "persist analysis"
}

public enum DJLoadFailurePresentation {
    public static func message(stage: DJLoadFailureStage, error: Error,
                               trackTitle: String, sourceURL: URL?, codec: String?) -> String {
        let detail = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        let location = sourceURL?.lastPathComponent.isEmpty == false
            ? sourceURL!.lastPathComponent : "unresolved source"
        let trimmedCodec = codec?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = trimmedCodec?.isEmpty == false ? trimmedCodec! : "unknown"
        return "\(trackTitle) failed during \(stage.rawValue). Source: \(location). Codec hint: \(hint). \(detail)"
    }
}
