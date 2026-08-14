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
                    NavigationLink(value: DJDestination.mixes) {
                        Label("Recorded Mixes", systemImage: "waveform.badge.record")
                            .accessibilityIdentifier("dj.mixes")
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
                case .mixes:
                    MixesView()
                }
            }
        }
    }
}

/// The performance surface the app root routes to (§49.3a). Built through
/// `DJWorkspaceAssembly` — the session, the engine, and the entitlement store
/// it gates on — and presented on the device-appropriate surface: the iPad
/// workspace or the iPhone compact solo/twin-deck surface. The assembly is
/// async (it enters the audio session before building the graph, §34A.2), so
/// the surface has an honest loading state; a nil result (the session or engine
/// cannot be constructed) is an honest unavailable state, never a dead surface.
struct DJPerformanceSurface: View {
    private enum LoadState {
        case loading
        case ready(WorkspaceModel)
        case unavailable
    }

    @State private var load: LoadState = .loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView()
            case .ready(let model):
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    WorkspaceView(model: model)
                } else {
                    CompactPerformanceView(model: model)
                }
                #else
                WorkspaceView(model: model)
                #endif
            case .unavailable:
                ContentUnavailableView {
                    Label("Decks unavailable", systemImage: "slider.horizontal.3")
                } description: {
                    Text("The audio session or engine could not be started.")
                }
            }
        }
        .task {
            if let model = await DJWorkspaceAssembly.makeModel() {
                load = .ready(model)
            } else {
                load = .unavailable
            }
        }
    }
}
