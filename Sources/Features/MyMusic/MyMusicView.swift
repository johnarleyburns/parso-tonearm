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
    @AppStorage("myMusic.selectedScope.v1") private var scope: Scope = .playlists
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

    enum Scope: String, CaseIterable, Identifiable {
        case playlists = "Playlists"
        #if os(iOS)
        case onMyWatch = "On My Watch"
        #endif
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
            #if os(iOS)
            case .onMyWatch: "On My Watch"
            #endif
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
            #if os(iOS)
            case .onMyWatch: return nil
            #endif
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

                if !appState.didLoadLibraryOnce {
                    ProgressView("Loading your music…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("mymusic.loading")
                } else {
                    switch scope {
                    #if os(iOS)
                    case .onMyWatch:
                        OnMyWatchMusicView()
                            .accessibilityIdentifier("mymusic.content.watch")
                    #endif
                    case .playlists:
                        PlaylistsView(ownsNavigationStack: false)
                            .accessibilityIdentifier("mymusic.content.playlists")
                    case .jamendo:
                        JamendoBrowseView(allowsImport: true, showsBackButton: false)
                            .accessibilityIdentifier("mymusic.content.jamendo")
                    case .artists, .albums, .songs, .genres:
                        LibraryView(ownsNavigationStack: false, externalMode: libraryModeBinding,
                                    filter: .init(), searchRows: nil, searchRowsRevision: 0,
                                    showsSearchField: false)
                            .accessibilityIdentifier("mymusic.content.music")
                    }
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
                    .accessibilityIdentifier("mymusic.scope.\(candidate.rawValue.lowercased().replacingOccurrences(of: " ", with: ""))")
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityIdentifier("mymusic.scope")
    }
}

#if os(iOS)
/// A mirror of watch-confirmed audio plus the phone's explicitly selected transfers.
private struct OnMyWatchMusicView: View {
    @EnvironmentObject var appState: AppState
    @State private var removal: PhoneWatchManagementPresenter.WatchTrackRow?
    @State private var pendingRemovalIDs: Set<String> = []

    var body: some View {
        List {
            Section {
                if let date = appState.watchManagement.syncHistory.lastWatchReportAt {
                    Text("Last watch report: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                } else {
                    Text("No watch report yet. Scheduled transfers below are not confirmed installed.")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Text("Choose music elsewhere in My Music and use Download to Watch to send it here.")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            if appState.watchManagement.watchTracks.isEmpty {
                Text(appState.watchManagement.syncHistory.lastWatchReportAt == nil
                     ? "Watch contents are unknown until its first report. No transfers are scheduled."
                     : "No audio reported on your watch or scheduled for transfer.")
                    .foregroundStyle(Palette.inkSecondary)
            }
            ForEach(appState.watchManagement.watchTracks) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: row.isInstalled ? "checkmark.circle.fill" : "applewatch")
                            .foregroundStyle(row.isInstalled ? Palette.accent : Palette.inkTertiary)
                            .accessibilityLabel(row.isInstalled ? "Installed on Apple Watch" : "Not confirmed installed")
                        Text(row.title).font(Typography.callout)
                        Spacer()
                        Button(role: .destructive) { removal = row } label: {
                            Image(systemName: "trash")
                        }.disabled(pendingRemovalIDs.contains(row.id))
                            .accessibilityIdentifier("mymusic.watch.remove.\(row.id)")
                    }
                    if pendingRemovalIDs.contains(row.id) {
                        Text("Removal requested; waiting for the watch report.").font(Typography.caption)
                    } else if row.isInstalled {
                        Text("Installed on Apple Watch").font(Typography.caption)
                    } else if let activity = row.activity {
                        Text(WatchStageCopy.text(activity.stage)).font(Typography.caption)
                        if activity.stage == .transferring, let fraction = activity.fractionComplete {
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))% transferred").font(Typography.caption)
                        }
                        if let message = activity.failureMessage { Text(message).font(Typography.caption) }
                        if activity.canRetry {
                            Button("Try Again") { Task { await appState.retryWatchJob(activity.requestID) } }
                        }
                    } else {
                        Text("Scheduled for Apple Watch").font(Typography.caption)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("mymusic.watch.track.\(row.id)")
            }
        }
        .listStyle(.plain)
        .task {
            while !Task.isCancelled {
                await appState.refreshWatchState()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Remove from Apple Watch?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let row = removal else { return }
                removal = nil
                pendingRemovalIDs.insert(row.id)
                Task { await appState.removeTrackFromWatch(row.id) }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Cancel its pending transfer and remove it from every selected watch collection. Your iPhone copy is kept.")
        }
    }
}
#endif
