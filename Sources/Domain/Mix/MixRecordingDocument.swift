import Foundation

/// A user's own recorded mix from the manual DJ console's REC button: a FLAC file plus the
/// metadata needed to list and play it. Unlike the removed `BlendDocument`, there is nothing to
/// re-resolve at playback time — the file itself is the mix.
public struct MixRecordingDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var durationSec: Double
    /// Path relative to the Mixes directory (`Application Support/Tonearm/Mixes/<fileRelPath>`).
    public var fileRelPath: String

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(),
                durationSec: Double, fileRelPath: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationSec = durationSec
        self.fileRelPath = fileRelPath
    }
}
