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
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var isRestoring = false

    var body: some View {
        NavigationStack(path: $entry.path) {
            List {
                // What the app believes about this purchase, and the one action
                // that fixes it being wrong (FR-STORE-3). No analytics — the
                // app sends nothing anywhere (NFR-PRIV-2) — so the way a tester
                // reports a purchase problem is by reading this row, which
                // means it has to state the *source* of the grant and not just
                // a checkmark.
                Section("Purchase") {
                    HStack {
                        Label(entitlements.isPro ? "Platterhead DJ · unlocked" : "Free tier",
                              systemImage: entitlements.isPro ? "checkmark.seal.fill" : "lock")
                        Spacer()
                        Text(entitlements.source.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("dj.purchase.status")
                    .accessibilityLabel(entitlements.isPro
                                        ? "Unlocked, \(entitlements.source.displayName)"
                                        : "Free tier")
                    if !entitlements.isPro {
                        Button {
                            isRestoring = true
                            Task {
                                await entitlements.restore()
                                isRestoring = false
                            }
                        } label: {
                            Text(isRestoring ? "Restoring…" : "Restore purchase")
                        }
                        .disabled(isRestoring)
                        .accessibilityIdentifier("dj.purchase.restore")
                    }
                }
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
            if let model = await DJWorkspaceAssembly.makeModel() {
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
        .onDisappear { appState.isPerformanceSurfaceFullScreen = false }
    }
}
