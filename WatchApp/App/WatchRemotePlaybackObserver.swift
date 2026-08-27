import Foundation
import TonearmWatchCore
import TonearmWatchProtocol

/// Feeds every phone playback snapshot the link delivers into `WatchRemotePlayer`, which owns the
/// prediction and the W7 surface. One of the fanout observers wired in `WatchAppAssembly`.
final class WatchRemotePlaybackObserver: WatchConnectivityObserver {
    func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async {
        await MainActor.run { WatchRemotePlayer.shared.apply(snapshot) }
    }
}
