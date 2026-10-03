#if !os(watchOS)
import AVFoundation
import Foundation
import os
import TonearmObjCSupport

/// The only place playback calls the AVPlayer APIs that raise an Objective-C exception — an app
/// abort Swift can't catch — when the player isn't ready to play:
///
/// - `preroll(atRate:)` (TestFlight 520: crossfade player prerolled straight after creation)
/// - `setRate(_:time:atHostTime:)` (TestFlight 521: the incoming track scheduled before it had
///   loaded)
///
/// Each call checks the documented precondition first and runs inside
/// `TonearmCatchObjCException`, so a precondition nobody has hit yet costs one transition, not the
/// app. `TransitionPlayerSafetyContractTests` fails if either API is called anywhere else.
enum TransitionPlayerControl {
    private static let log = Logger(subsystem: "com.platterhead.tonearm", category: "transition")

    /// Ready for preroll and synchronized playback: the player and its item have loaded, and it
    /// doesn't wait to minimise stalling (synchronized playback raises if it does).
    static func isReady(_ player: AVPlayer) -> Bool {
        player.status == .readyToPlay
            && player.currentItem?.status == .readyToPlay
            && !player.automaticallyWaitsToMinimizeStalling
    }

    /// Prerolls a paused, ready player. Returns false (and does nothing) otherwise.
    @discardableResult
    static func preroll(_ player: AVPlayer, rate: Float) -> Bool {
        guard isReady(player), player.rate == 0, rate.isFinite, rate > 0 else { return false }
        return perform("preroll") { player.preroll(atRate: rate) { _ in } }
    }

    /// Starts `player` at `itemTime` when the host clock reaches `hostTime`. Returns false, without
    /// touching the player, when it isn't ready or the times aren't usable.
    static func schedule(_ player: AVPlayer, rate: Float, itemTime: CMTime, hostTime: CMTime) -> Bool {
        guard isReady(player), rate.isFinite, rate > 0,
              itemTime.isNumeric, hostTime.isNumeric else { return false }
        return perform("synchronized start") {
            player.setRate(rate, time: itemTime, atHostTime: hostTime)
        }
    }

    private static func perform(_ what: String, _ call: () -> Void) -> Bool {
        guard let exception = TonearmCatchObjCException(call) else { return true }
        log.error("AVPlayer \(what, privacy: .public) raised \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "", privacy: .public)")
        return false
    }
}
#endif
