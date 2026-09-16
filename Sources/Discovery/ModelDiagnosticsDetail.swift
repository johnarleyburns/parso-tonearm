#if !os(watchOS)
import Foundation

/// The full, per-artefact breakdown for the Sound Index screen's "Models"
/// section — added directly at the user's request for an interactive debug
/// session ("at the minimum I want the Sound Index view to have a 'Models'
/// section... show each model, the percentage downloaded, MB downloaded, if
/// it's complete or not, any errors, also show active downloading, we need
/// this level of detail to know what's going on"). Every field here is real,
/// currently-observed state — never fabricated (CLAUDE.md "no silent/magic
/// background work").
///
/// This is deliberately a SEPARATE, more detailed view of the same
/// underlying facts `ModelDownloadProgress`/`IndexStatusSnapshot` already
/// track in aggregate — the aggregate view is what most users need
/// ("downloading — 1 of 2 components ready"), this is what a real
/// diagnostic session needs (which specific artefact, exactly what state).
public struct ModelDiagnosticsDetail: Equatable, Sendable {
    /// One ODR tag's raw download state (`clap-audio`, `clap-text`).
    public struct DownloadTag: Equatable, Sendable, Identifiable {
        public var id: String { tag }
        public var tag: String
        public var completedBytes: Int64
        public var totalBytes: Int64
        public var isFinished: Bool

        public init(tag: String, completedBytes: Int64, totalBytes: Int64, isFinished: Bool) {
            self.tag = tag
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
            self.isFinished = isFinished
        }

        /// Same rounding/trust rule as `ModelDownloadProgress.isNegligibleTotal`
        /// — `NSBundleResourceRequest.progress`'s unit is not guaranteed to be
        /// real bytes (confirmed on a real device: both tags reported literal
        /// `totalUnitCount == 1`), so a total this small must be labeled as
        /// such rather than shown as a real byte count.
        public var bytesAreTrustworthy: Bool {
            Int((Double(totalBytes) / 1_048_576).rounded()) > 0
        }

        public var fractionComplete: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }

        /// The state word for this tag, independent of whether the bytes are
        /// trustworthy — this is what lets the UI say "in progress" even
        /// when it can't show a real percentage.
        public enum State: String, Sendable {
            case notStarted, inProgress, finished
        }

        public var state: State {
            if isFinished { return .finished }
            return totalBytes > 0 ? .inProgress : .notStarted
        }
    }

    /// One required on-disk artefact (audio encoder, text encoder, mel
    /// filterbank, tokenizer vocab/merges) and whether `ModelResourceLocator`
    /// can currently find it. This is the field that would have caught the
    /// real session-long bug directly: every download tag could say
    /// "finished" while every artefact here still said "not found" — the
    /// download completing and the file actually being locatable are TWO
    /// DIFFERENT facts, and this view is what keeps them visibly separate.
    public struct Artifact: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var isResolved: Bool
        /// The resolved file/folder name (e.g. "CLAPAudioEncoder.mlmodelc"),
        /// not the full path — never leak an absolute on-device path into a
        /// diagnostics export (plan §10.6 redaction).
        public var resolvedName: String?

        public init(name: String, isResolved: Bool, resolvedName: String? = nil) {
            self.name = name
            self.isResolved = isResolved
            self.resolvedName = resolvedName
        }
    }

    public var downloadTags: [DownloadTag]
    public var artifacts: [Artifact]
    /// The most recent ODR fetch error, if any — same value as
    /// `IndexStatusSnapshot.modelDownloadError`, repeated here so the
    /// Models section is a complete, self-contained picture on its own.
    public var downloadError: String?

    public init(downloadTags: [DownloadTag], artifacts: [Artifact], downloadError: String? = nil) {
        self.downloadTags = downloadTags
        self.artifacts = artifacts
        self.downloadError = downloadError
    }
}
#endif
