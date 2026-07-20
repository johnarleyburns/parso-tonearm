import Foundation

public protocol WatchAudioOutput: AnyObject, Sendable {
    func load(url: URL) async
    func play() async
    func pause() async
    func seek(to time: Double) async
    var onItemEnded: (() -> Void)? { get set }
    var onItemFailed: (() -> Void)? { get set }
    var onTimeUpdate: ((Double) -> Void)? { get set }
}
