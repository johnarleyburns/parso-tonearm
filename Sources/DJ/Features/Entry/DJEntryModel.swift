import Combine
import Foundation
import TonearmCore

// MARK: - App entry (spec §49.3a, plan 5.1)

/// The destinations the app root can route the DJ feature to. Rule 1 of the
/// reachability invariant (§49.3a) is that a feature is not done until it is
/// reachable — the app's root owns a route table, and this is that table in a
/// testable form. The app-side `DJHomeView` binds its `NavigationStack` path to
/// `DJEntryModel.path`; the §49.3a test asserts every surface is on it.
public enum DJDestination: Hashable, Sendable {
    /// The performance surface — the workspace, Pro-gated at the model.
    case decks
    /// The DJ library (import, prep, playlists).
    case library
}

/// The DJ entry point model: the route table from the app root (§49.3a rule 1)
/// and the navigation path the app-side home drives. A small value the view
/// binds to, so the reachability invariant is an executable contract.
@MainActor
public final class DJEntryModel: ObservableObject {
    /// Every user-facing DJ surface, in navigation order — the §49.3a
    /// reachable set. A surface added to the milestone without landing here is
    /// dead code in the shipped binary, exactly the failure M4 shipped.
    public static let reachableDestinations: [DJDestination] = [.decks, .library]

    /// The active navigation path (empty = the home). The app-side
    /// `DJHomeView` binds its `NavigationStack` to this.
    @Published public var path: [DJDestination] = []

    public init() {}

    /// Push a destination — the route table's navigation action (the view's
    /// `NavigationLink` does the same via the path binding; kept here so the
    /// reachable set's navigation is testable).
    public func present(_ destination: DJDestination) {
        path.append(destination)
    }

    /// Pop back to the DJ home.
    public func popToHome() {
        path.removeAll()
    }
}

/// Builds the workspace session model from the app root's inputs. Kept here so
/// the performance surface's construction — the engine and the entitlement
/// store it gates on — is testable off-device (§49.3a: reachable *and* built
/// with real dependencies).
public enum DJWorkspaceAssembly {
    /// The app-root's one way into the decks. Returns nil when the session
    /// cannot be entered or the engine cannot be constructed — an honest
    /// absence, never a crash: the route then shows an unavailable state
    /// instead of a dead surface.
    ///
    /// **Plan 5.4a (§53.11):** the engine runs in `.realtime` rendering mode and
    /// the audio session is entered in the §34A.2 normative order — **category →
    /// preferences → activate → read back → build the graph** — so the engine is
    /// negotiated against the active session. On hosts with no `AVAudioSession`
    /// (macOS tests/previews) the coordinator is unavailable and the engine is
    /// still built: CoreAudio drives the realtime graph there.
    @MainActor
    public static func makeModel(store: EntitlementStore = .shared,
                                 session: AudioSessionCoordinator = AudioSessionCoordinator(),
                                 allowBluetooth: Bool = false) async -> WorkspaceModel? {
        do {
            _ = try await session.enter(.performing, allowBluetooth: allowBluetooth)
        } catch AudioSessionCoordinator.SessionError.unavailableOnThisPlatform {
            // macOS: no `AVAudioSession` to enter; the realtime graph still
            // works, so continue rather than refusing the surface.
        } catch {
            // A refused Bluetooth route or an activate failure is an honest
            // unavailable state — a graph built against an unactivated session
            // would be silent or misconfigured (§34A.2).
            return nil
        }
        guard let engine = try? PerformanceEngine(configuration: .init(maximumFrameCount: 128,
                                                                       rendering: .realtime,
                                                                       recordTapEnabled: true)) else {
            return nil
        }
        return WorkspaceModel(engine: engine, store: store, session: session)
    }
}
