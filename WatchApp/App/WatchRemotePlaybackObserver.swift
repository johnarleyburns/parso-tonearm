import Foundation
import TonearmWatchCore
import TonearmWatchProtocol

/// Feeds every phone playback snapshot the link delivers into `WatchRemotePlayer`, which owns the
/// prediction and the W7 surface, and arms the §7.5 "Continue on Apple Watch" offer on a confirmed
/// disconnect. One of the fanout observers wired in `WatchAppAssembly`.
final class WatchRemotePlaybackObserver: WatchConnectivityObserver {
    func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async {
        await MainActor.run { WatchRemotePlayer.shared.apply(snapshot) }
    }

    func didConfirmDisconnection() async {
        await MainActor.run { WatchPlaybackCoordinator.shared.armContinueFromDisconnect() }
    }

    func didReconnect() async {
        await MainActor.run { WatchPlaybackCoordinator.shared.clearContinueOnReconnect() }
    }
}
