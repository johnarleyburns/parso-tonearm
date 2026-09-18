import SwiftUI
import TonearmCore
import TonearmDJ

/// The DJ tab's home (plan 5.1, spec §49.3a): the app root's navigable route
/// into the DJ feature set. Every destination is on `DJEntryModel`
/// .reachableDestinations — the §49.3a route table — so a surface that is not
/// reachable from here is dead code in the shipped binary.
///
/// Business decision (see
/// docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §11):
/// everything here is free — no Pro entitlement, no paywall, no purchase
/// gate. The "Purchase"/unlocked-vs-free-tier section that used to sit above
/// "Library" is gone; `EntitlementStore` still exists and still always
/// reports `isPro == true` (a prior, already-shipped business decision —
/// nothing here was ever actually gated), but nothing in this view surfaces
/// it anymore. Removing the underlying `EntitlementStore`/`ProCapability`
/// plumbing from `WorkspaceModel`/`TrackPrepModel` is a separate, deeper
/// follow-up — deferred because it reaches into the live DJ performance
/// surface (`WorkspaceView`/`SoloDeckView`/`TwinDeckView`), which is
/// untouched and untested this session.
struct DJHomeView: View {
    @StateObject private var entry = DJEntryModel()
    @State private var showPlaylists = false

    var body: some View {
        NavigationStack(path: $entry.path) {
            List {
                Section("Library") {
                    Button { showPlaylists = true } label: {
                        Label("Playlists", systemImage: "music.note.list")
                            .accessibilityIdentifier("dj.playlists")
                    }
                    NavigationLink(value: DJDestination.mixes) {
                        Label("Recorded Mixes", systemImage: "recordingtape.circle.fill")
                            .accessibilityIdentifier("dj.mixes")
                    }
                }
                Section("Perform") {
                    NavigationLink(value: DJDestination.decks) {
                        Label("Open DJ Mixer", systemImage: "slider.horizontal.3")
                            .accessibilityIdentifier("dj.decks")
                    }
                }
                Section("Hardware") {
                    NavigationLink(value: DJDestination.midi) {
                        Label("MIDI controller", systemImage: "pianokeys")
                            .accessibilityIdentifier("dj.midi")
                    }
                }
            }
            .sheet(isPresented: $showPlaylists) {
                PlaylistsView(presentsCreateSheetLocally: true)
            }
            .navigationTitle("Platterhead DJ")
            .navigationDestination(for: DJDestination.self) { destination in
                switch destination {
                case .decks:
                    DJPerformanceSurface()
                case .mixes:
                    MixesView()
                case .midi:
                    MidiSettingsView(model: MidiSettingsModel.live())
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

    @EnvironmentObject private var appState: AppState
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
            if let model = await DJWorkspaceAssembly.makeModel(
                midiProfileStore: ControllerProfileStore(pool: ControllerProfileDatabase.shared)) {
                load = .ready(model)
            } else {
                load = .unavailable
            }
        }
        // The decks are a full-screen instrument: the app's dock would otherwise
        // cover the crossfader and the transport chips on the bottom edge, which
        // §42.7a forbids — and a covered control is not merely hidden, it is
        // unreachable, because the overlay takes the touch.
        .onAppear { appState.isPerformanceSurfaceFullScreen = true }
        .onDisappear {
            // The MIDI client follows the surface's lifetime (plan dj-midi-alpha
            // M1): a detached workspace cancels its message task and releases the
            // `HardwareService`; the next open attaches again if a profile exists.
            if case .ready(let model) = load { model.detachMidi() }
            appState.isPerformanceSurfaceFullScreen = false
        }
    }
}
