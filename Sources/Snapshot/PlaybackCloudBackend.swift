import Foundation

/// Testable abstraction over the cloud persistence of playback state (G6).
/// The production implementation pushes/pulls a `playback-state` CloudKit
/// record; tests install an in-memory fake to simulate reinstall scenarios.
public protocol PlaybackCloudBackend: AnyObject {
    func load() async -> PlaybackStateSnapshot?
    func save(_ snapshot: PlaybackStateSnapshot)
}

/// In-memory fake for tests: simulates the cloud tier so reinstall tests can
/// wipe the file+defaults tiers and verify the snapshot comes back from cloud.
public final class FakePlaybackCloudBackend: PlaybackCloudBackend {
    private var storage: PlaybackStateSnapshot?

    public init() {}

    public func load() async -> PlaybackStateSnapshot? { storage }

    public func save(_ snapshot: PlaybackStateSnapshot) { storage = snapshot }
}
