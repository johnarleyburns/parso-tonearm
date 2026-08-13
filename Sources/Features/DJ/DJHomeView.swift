import SwiftUI
import TonearmCore
import TonearmDJ

/// The DJ tab's home (plan 5.1, spec §49.3a): the app root's navigable route
/// into the DJ feature set. Every destination is on `DJEntryModel`
/// .reachableDestinations — the §49.3a route table — so a surface that is not
/// reachable from here is dead code in the shipped binary. The performance
/// surface is Pro-gated by the workspace's own model gate: free users see the
/// real dimmed surface with a lock chip (§40.4), and the paywall is presented
/// from the chip (FR-STORE-5).
struct DJHomeView: View {
    @StateObject private var entry = DJEntryModel()

    var body: some View {
        NavigationStack(path: $entry.path) {
            List {
                Section("Perform") {
                    NavigationLink(value: DJDestination.decks) {
                        Label("Open the decks", systemImage: "slider.horizontal.3")
                            .accessibilityIdentifier("dj.decks")
                    }
                }
                Section("Library") {
                    NavigationLink(value: DJDestination.library) {
                        Label("Music", systemImage: "music.note.list")
                            .accessibilityIdentifier("dj.library")
                    }
                }
            }
            .navigationTitle("Platterhead DJ")
            .navigationDestination(for: DJDestination.self) { destination in
                switch destination {
                case .decks:
                    DJPerformanceSurface()
                case .library:
                    LibraryView()
                }
            }
        }
    }
}

/// The performance surface the app root routes to (§49.3a). Built through
/// `DJWorkspaceAssembly` — the engine and the entitlement store it gates on —
/// and presented on the device-appropriate surface: the iPad workspace or the
/// iPhone compact solo/twin-deck surface. A nil model (the engine cannot be
/// constructed) is an honest unavailable state, never a dead surface.
struct DJPerformanceSurface: View {
    @State private var model: WorkspaceModel?

    init() {
        _model = State(initialValue: DJWorkspaceAssembly.makeModel())
    }

    var body: some View {
        Group {
            if let model {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    WorkspaceView(model: model)
                } else {
                    CompactPerformanceView(model: model)
                }
                #else
                WorkspaceView(model: model)
                #endif
            } else {
                ContentUnavailableView {
                    Label("Decks unavailable", systemImage: "slider.horizontal.3")
                } description: {
                    Text("The audio engine could not be started.")
                }
            }
        }
    }
}
