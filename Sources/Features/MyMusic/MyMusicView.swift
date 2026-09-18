import SwiftUI
import TonearmCore

/// The unified collection surface — replaces the former standalone
/// Playlists and Music (Library) root tabs (see
/// docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §4).
///
/// One unified scope bar (Playlists/Artists/Albums/Songs/Genres) drives both
/// `PlaylistsView` and `LibraryView` — `LibraryView`'s own internal
/// Artists/Albums/Songs/Genres picker is driven externally via
/// `externalMode` rather than duplicated (docs/plans/ui-simplification-plan.md
/// item 4; this used to stack a second Music/Playlists picker on top of
/// LibraryView's own one, which read as two nested pickers).
struct MyMusicView: View {
    @EnvironmentObject var appState: AppState
    @State private var scope: Scope = .artists

    enum Scope: String, CaseIterable, Identifiable {
        case playlists = "Playlists"
        case artists = "Artists"
        case albums = "Albums"
        case songs = "Songs"
        case genres = "Genres"
        var id: String { rawValue }

        var libraryMode: LibraryBrowseMode? {
            switch self {
            case .playlists: return nil
            case .artists: return .artists
            case .albums: return .albums
            case .songs: return .songs
            case .genres: return .genres
            }
        }

        init(libraryMode: LibraryBrowseMode) {
            switch libraryMode {
            case .artists: self = .artists
            case .albums: self = .albums
            case .songs: self = .songs
            case .genres: self = .genres
            }
        }
    }

    private var libraryModeBinding: Binding<LibraryBrowseMode> {
        Binding(
            get: { scope.libraryMode ?? .artists },
            set: { scope = Scope(libraryMode: $0) }
        )
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
                case .playlists:
                    PlaylistsView(ownsNavigationStack: false)
                        .accessibilityIdentifier("mymusic.scope.playlists")
                case .artists, .albums, .songs, .genres:
                    LibraryView(ownsNavigationStack: false, externalMode: libraryModeBinding)
                        .accessibilityIdentifier("mymusic.scope.music")
                }
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
