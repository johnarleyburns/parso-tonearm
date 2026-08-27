import Foundation

@MainActor public protocol WatchAudioOutput: AnyObject {
    func load(url: URL) async
    func play() async
    func pause() async
    func seek(to time: Double) async
    /// Apply a 0...1 output volume (Crown-driven). Clamped by the implementation.
    func setVolume(_ volume: Double)
    /// Reconfigure + reactivate the audio session and reload whatever item is current. Used after an
    /// interruption that requires a session rebuild and after a media-services reset.
    func rebuildSession() async
    var onItemEnded: (() -> Void)? { get set }
    var onItemFailed: (() -> Void)? { get set }
    var onTimeUpdate: ((Double) -> Void)? { get set }
}

/// Apply a batch of engine directives to an output **in order**, awaiting each before the next.
///
/// This exists because `.loadItem` must complete before `.play`, and spawning one detached `Task`
/// per directive (an easy mistake) races them. Kept here, pure and host-testable, so a spy can prove
/// the ordering (§9b "spy output directive order").
@MainActor
public func applyWatchDirectives(_ directives: [WatchEngineDirective],
                                 to output: WatchAudioOutput) async {
    for directive in directives {
        switch directive {
        case .loadItem(let url): await output.load(url: url)
        case .play: await output.play()
        case .pause: await output.pause()
        case .seek(let time): await output.seek(to: time)
        case .stop: await output.pause()
        }
    }
}
