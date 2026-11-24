import Foundation

/// Testable abstraction over an optional external persistence tier for playback
/// state (G6). Production leaves it unset; tests install an in-memory fake to
/// simulate reinstall scenarios.
public protocol PlaybackCloudBackend: AnyObject, Sendable {
    func load() async -> PlaybackStateSnapshot?
    func save(_ snapshot: PlaybackStateSnapshot)
}

/// In-memory fake for tests: simulates the cloud tier so reinstall tests can
/// wipe the file+defaults tiers and verify the snapshot comes back from cloud.
public final class FakePlaybackCloudBackend: @unchecked Sendable, PlaybackCloudBackend {
    private var storage: PlaybackStateSnapshot?

    public init() {}

    public func load() async -> PlaybackStateSnapshot? { storage }

    public func save(_ snapshot: PlaybackStateSnapshot) { storage = snapshot }
}
