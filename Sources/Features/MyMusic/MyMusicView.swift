import SwiftUI
import TonearmCore

/// The unified collection surface — replaces the former standalone
/// Playlists and Music (Library) root tabs (see
/// docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §4).
///
/// This is a pragmatic first cut: it composes the two existing, already-
/// working screens (`LibraryView`, `PlaylistsView`) behind one scope picker
/// rather than rebuilding their internals — `LibraryView` already owns its
/// own Artists/Albums/Songs/Genres browse picker, search field, and
/// "Find by sound" entry point, so nesting a second picker on top of it
/// would just duplicate UI. The plan's full five-way scope bar (All/
/// Playlists/Artists/Albums/Songs) is a follow-up once that duplication is
/// worth resolving.
struct MyMusicView: View {
    @EnvironmentObject var appState: AppState
    @State private var scope: Scope = .music

    enum Scope: String, CaseIterable, Identifiable {
        case music = "Music"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("My Music Scope", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityIdentifier("mymusic.scope")

                switch scope {
                case .music:
                    LibraryView(ownsNavigationStack: false)
                        .accessibilityIdentifier("mymusic.scope.music")
                case .playlists:
                    PlaylistsView(ownsNavigationStack: false)
                        .accessibilityIdentifier("mymusic.scope.playlists")
                }
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
