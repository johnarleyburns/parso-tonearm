#if !os(watchOS)
import Foundation
import Network

/// `AudioPlayer`'s only two uses of `NWPathMonitor`: whether the network is
/// currently usable, and whether path changes are expensive. `NWPath` has no
/// public initializer, so (unlike `PlayerEngine`/`AVPlayer`) this can't match
/// `NWPathMonitor`'s own surface 1:1 — it exposes exactly what `AudioPlayer`
/// reads instead, so a test fake can satisfy it with plain stored state.
protocol NetworkPathMonitoring: AnyObject {
    var isAvailable: Bool { get }
    var pathUpdateHandler: ((_ isExpensive: Bool) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

/// Wraps the real `NWPathMonitor` production has always used. `pathUpdateHandler`
/// still fires off whatever queue `start(queue:)` was given, exactly as today —
/// `AudioPlayer`'s own `observeNetworkPath()` does the `@MainActor` hop.
final class RealNetworkPathMonitor: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()

    var isAvailable: Bool { monitor.currentPath.status == .satisfied }

    var pathUpdateHandler: ((Bool) -> Void)? {
        didSet {
            monitor.pathUpdateHandler = { [weak self] path in
                self?.pathUpdateHandler?(path.isExpensive)
            }
        }
    }

    func start(queue: DispatchQueue) { monitor.start(queue: queue) }
    func cancel() { monitor.cancel() }
}
#endif
