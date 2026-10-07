import Foundation

/// Application-level checkpoints, not the opaque byte progress of a WCSession file.
public enum WatchAudioChunkPolicy {
    public static let defaultChunkBytes = 1024 * 1024
    public static let maximumChunkBytes = 4 * 1024 * 1024
    public static let maximumChunks = 8192
    public static let maximumUnconfirmedChunks = 1
    public static let acknowledgementTimeout: TimeInterval = 300
}

public struct WatchPartialAudioDownload: Codable, Equatable, Sendable {
    public var trackID: WatchTrackID
    public var assetSHA256: String
    public var totalBytes: Int64
    public var chunkBytes: Int
    public var receivedChunkIndexes: [Int]

    public init(trackID: WatchTrackID, assetSHA256: String, totalBytes: Int64,
                chunkBytes: Int, receivedChunkIndexes: [Int]) {
        self.trackID = trackID; self.assetSHA256 = assetSHA256; self.totalBytes = totalBytes
        self.chunkBytes = chunkBytes; self.receivedChunkIndexes = receivedChunkIndexes
    }
    public var chunkCount: Int { totalBytes > 0 && chunkBytes > 0 ? Int((totalBytes - 1) / Int64(chunkBytes) + 1) : 0 }
    public var retainedBytes: Int64 {
        Set(receivedChunkIndexes).filter { $0 >= 0 && $0 < chunkCount }.reduce(0) {
            $0 + min(Int64(chunkBytes), totalBytes - Int64($1) * Int64(chunkBytes))
        }
    }
    public var fractionRetained: Double { totalBytes > 0 ? Double(retainedBytes) / Double(totalBytes) : 0 }
}

public struct WatchAudioChunkMetadata: Codable, Equatable, Sendable {
    public static let assetKind = "audioChunk"
    public var audio: WatchAudioFileMetadata
    public var chunkBytes: Int
    public var index: Int
    public var chunkSHA256: String
    public var transferID: String

    public init(audio: WatchAudioFileMetadata, chunkBytes: Int, index: Int,
                chunkSHA256: String, transferID: String = UUID().uuidString) {
        self.audio = audio; self.chunkBytes = chunkBytes; self.index = index
        self.chunkSHA256 = chunkSHA256; self.transferID = transferID
    }
    public var chunkCount: Int { audio.expectedBytes > 0 && chunkBytes > 0 ? Int((audio.expectedBytes - 1) / Int64(chunkBytes) + 1) : 0 }
    public var expectedChunkBytes: Int64 { min(Int64(chunkBytes), audio.expectedBytes - Int64(index) * Int64(chunkBytes)) }
    public var isValid: Bool {
        guard !audio.trackID.rawValue.isEmpty, audio.expectedBytes > 0,
              chunkBytes > 0, chunkBytes <= WatchAudioChunkPolicy.maximumChunkBytes,
              chunkCount <= WatchAudioChunkPolicy.maximumChunks, index >= 0, index < chunkCount,
              let assetSHA = audio.sha256 else { return false }
        return Self.isDigest(assetSHA) && Self.isDigest(chunkSHA256) && !transferID.isEmpty
    }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }

    public var dictionary: [String: String] {
        // Prefix the original descriptor. Older receivers cannot mistake a partial chunk
        // for a complete audio file (there is intentionally no top-level expectedBytes).
        var result = Dictionary(uniqueKeysWithValues: audio.dictionary.map { ("audio." + $0.key, $0.value) })
        result["assetKind"] = Self.assetKind; result["chunkBytes"] = String(chunkBytes)
        result["chunkIndex"] = String(index); result["chunkSHA256"] = chunkSHA256
        result["chunkTransferID"] = transferID
        return result
    }
    public init?(dictionary: [String: String]) {
        guard dictionary["assetKind"] == Self.assetKind,
              let size = dictionary["chunkBytes"].flatMap(Int.init),
              let index = dictionary["chunkIndex"].flatMap(Int.init),
              let digest = dictionary["chunkSHA256"], let transferID = dictionary["chunkTransferID"] else { return nil }
        let rawAudio = Dictionary(uniqueKeysWithValues: dictionary.filter { $0.key.hasPrefix("audio.") }
            .map { (String($0.key.dropFirst(6)), $0.value) })
        guard let audio = WatchAudioFileMetadata(dictionary: rawAudio) else { return nil }
        self.init(audio: audio, chunkBytes: size, index: index, chunkSHA256: digest, transferID: transferID)
        guard isValid else { return nil }
    }
}
