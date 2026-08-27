import Foundation
import TonearmWatchProtocol

/// The watch's connection chrome model (§9 W1/W5/W12 banner, C-08/C-09).
///
/// A blip moves the banner to `.temporarilyUnavailable` but never switches the app out of connected
/// mode; only a confirmed outage does. `disconnectPulse` increments exactly once per confirmed
/// outage so a view can fire a single haptic without tracking edges itself.
@MainActor
public final class WatchConnectionChrome: ObservableObject {
    public enum Banner: String, Equatable, Sendable {
        /// No banner — the phone is reachable.
        case connected
        /// A sub-grace blip: chrome shows a transient hint, mode stays connected.
        case temporarilyUnavailable
        /// A confirmed outage: the app is an offline player until the phone returns.
        case unavailable
        /// The phone speaks a newer protocol; only downloaded music is usable.
        case incompatible
    }

    @Published public private(set) var banner: Banner
    /// The incoming phone library identity when it differs from the bound one (A-08). The UI must
    /// ask the user before `WatchConnectivityCoordinator.confirmPairedLibraryReplacement()`.
    @Published public private(set) var pendingLibraryReplacement: WatchPairedLibraryID?
    @Published public private(set) var disconnectPulse = 0
    @Published public private(set) var reconnectPulse = 0

    /// Starts `.unavailable`: the watch is an offline player until negotiation proves the phone is
    /// reachable, so a launch with no phone shows a usable downloaded library, never broken rows.
    public init(initial: Banner = .unavailable) {
        self.banner = initial
    }

    /// True while connected phone features (search, browse-on-iPhone, play-on-iPhone) are offered.
    public var showsConnectedFeatures: Bool { banner == .connected }
    /// True when the offline "iPhone unavailable" banner should be shown (§9 W5 — once, then quiet).
    public var showsOfflineBanner: Bool { banner == .unavailable || banner == .incompatible }

    public func apply(connectivity: WatchConnectivityState) {
        guard banner != .incompatible else { return }
        switch connectivity {
        case .connected:
            banner = .connected
        case .opening, .temporarilyUnavailable:
            if banner == .connected { banner = .temporarilyUnavailable }
        case .unavailable:
            banner = .unavailable
        }
    }

    public func markIncompatible() { banner = .incompatible }

    public func confirmedDisconnection() {
        banner = .unavailable
        disconnectPulse += 1
    }

    public func reconnected() {
        if banner != .incompatible { banner = .connected }
        reconnectPulse += 1
    }

    public func requestLibraryReplacement(current: WatchPairedLibraryID, incoming: WatchPairedLibraryID) {
        pendingLibraryReplacement = incoming
    }

    public func resolveLibraryReplacement() { pendingLibraryReplacement = nil }
}
