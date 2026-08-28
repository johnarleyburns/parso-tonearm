import Foundation
import TonearmWatchCore
import TonearmWatchProtocol

/// Feeds every phone playback snapshot the link delivers into `WatchRemotePlayer`, which owns the
/// prediction and the W7 surface, and arms the §7.5 "Continue on Apple Watch" offer on a confirmed
/// disconnect. One of the fanout observers wired in `WatchAppAssembly`.
actor WatchRemotePlaybackObserver: WatchConnectivityObserver {
    /// When the link was last confirmed down — used to measure the disconnect duration (§12).
    private var disconnectedAt: Date?

    func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async {
        await MainActor.run { WatchRemotePlayer.shared.apply(snapshot) }
    }

    func didConfirmDisconnection() async {
        disconnectedAt = Date()
        await WatchAppAssembly.shared.diagnostics.record(.routeEvent, "disconnected")
        await MainActor.run { WatchPlaybackCoordinator.shared.armContinueFromDisconnect() }
    }

    func didReconnect() async {
        let downMillis = disconnectedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        disconnectedAt = nil
        await WatchAppAssembly.shared.diagnostics.record(.disconnectDuration, "reconnected",
                                                         durationMillis: downMillis)
        await MainActor.run { WatchPlaybackCoordinator.shared.clearContinueOnReconnect() }
    }
}
