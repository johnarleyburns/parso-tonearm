import SwiftUI
import TonearmCore
import TonearmDiscovery

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
    /// Real gap found auditing the mood-based-listening plan (docs/plans/
    /// mood-based-listening-plan.md §3.5's second audit note): landing on a
    /// specific artist from another tab is a genuinely PUSHED navigation
    /// destination, and there was no way to push into this stack
    /// programmatically before this — a plain `NavigationStack { … }` only
    /// responds to a user's own `NavigationLink` tap. `NavigationPath` (not
    /// a typed array/enum) because this one stack already carries two
    /// different `navigationDestination` types (`Playlist.self` from the
    /// embedded `PlaylistsView`, `String.self` for the "ambient" row) plus
    /// `LibraryBrowse.Entry.self` from `LibraryView` — `NavigationPath`
    /// accepts any `Hashable` without unifying them under one shared type.
    @State private var navigationPath = NavigationPath()
    @State private var searchMode: MyMusicSearchMode = .all
    @State private var mixBPMPreset: MixBPMPreset?
    @State private var mixKey: String?
    @State private var soundSearchRows: [TrackRow]?
    @State private var soundSearchRevision = 0

    enum Scope: String, CaseIterable, Identifiable {
        case playlists = "Playlists"
        case artists = "Artists"
        case albums = "Albums"
        case songs = "Songs"
        case genres = "Genres"
        case jamendo = "Jamendo"
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .playlists: "Playlists"
            case .artists: "Artists"
            case .albums: "Albums"
            case .songs: "Songs"
            case .genres: "Genres"
            case .jamendo: "Jamendo"
            }
        }

        var libraryMode: LibraryBrowseMode? {
            switch self {
            case .playlists: return nil
            case .artists: return .artists
            case .albums: return .albums
            case .songs: return .songs
            case .genres: return .genres
            case .jamendo: return nil
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
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                scopePicker

                switch scope {
                case .playlists:
                    PlaylistsView(ownsNavigationStack: false)
                        .accessibilityIdentifier("mymusic.content.playlists")
                case .jamendo:
                    JamendoBrowseView(allowsImport: true, showsBackButton: false)
                        .accessibilityIdentifier("mymusic.content.jamendo")
                case .artists, .albums, .songs, .genres:
                    MyMusicSearchControls(mode: $searchMode, bpmPreset: $mixBPMPreset,
                                          mixKey: $mixKey,
                                          onSoundRows: { rows in
                                              soundSearchRows = rows
                                              soundSearchRevision &+= 1
                                          })
                    LibraryView(ownsNavigationStack: false, externalMode: libraryModeBinding,
                                filter: currentFilter,
                                searchRows: searchMode == .sound ? soundSearchRows : nil,
                                searchRowsRevision: soundSearchRevision,
                                showsSearchField: false)
                        .accessibilityIdentifier("mymusic.content.music")
                }
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .hiddenNavigationBar()
        }
        .task {
            // On Mac the search field is the window toolbar's, and typing in
            // it is what brings My Music forward — keep what was typed.
            #if os(iOS)
            appState.searchText = ""
            #endif
            consumePendingArtistFilter()
        }
    }

    private var currentFilter: MyMusicFilter {
        guard searchMode == .mix else { return .init() }
        return MyMusicFilter(
            mixBPM: mixBPMPreset.map { ($0.range.lowerBound + $0.range.upperBound) / 2 },
            mixBPMRange: mixBPMPreset?.range,
            mixKey: mixKey)
    }

    /// One-shot launch-intent consumption for a Top Artist row's tap on the
    /// Listen tab (docs/plans/mood-based-listening-plan.md §3.5). Resolves
    /// the artist NAME into a real `LibraryBrowse.Entry` — the only existing
    /// way to produce one is rebuilding sections from the current library —
    /// and pushes it. A name with no exact match degrades safely: the
    /// Artists scope still opens, just without drilling further, rather
    /// than crashing on a lookup failure.
    private func consumePendingArtistFilter() {
        guard let artistName = appState.pendingArtistFilter else { return }
        appState.pendingArtistFilter = nil
        scope = .artists
        let entries = LibraryBrowse.sections(for: .artists, rows: appState.allTracks).flatMap(\.entries)
        guard let match = entries.first(where: { $0.title == artistName }) else { return }
        navigationPath.append(match)
    }

    /// A scrollable chip row rather than a native 5-item `.segmented`
    /// picker — five real labels (Playlists/Artists/Albums/Songs/Genres) is
    /// past where `UISegmentedControl` still fits comfortably at phone
    /// width without shrinking or truncating text.
    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases) { candidate in
                    let selected = candidate == scope
                    Button { scope = candidate } label: {
                        Text(candidate.title)
                            .font(Typography.callout)
                            .foregroundStyle(selected ? Palette.accentOnFill : Palette.inkSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selected ? Palette.accent : Palette.ink.opacity(0.07),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mymusic.scope.\(candidate.rawValue.lowercased())")
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityIdentifier("mymusic.scope")
    }
}
