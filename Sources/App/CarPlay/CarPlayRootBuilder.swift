import CarPlay
import TonearmCore

/// Builds the CarPlay template hierarchy: a tab bar mirroring the phone
/// app's most-used browse surfaces (Playlists/Library/Search/Recently
/// Played/Favorites — CarPlay caps a tab bar at 5 tabs, so this
/// deliberately doesn't try to mirror the full My Music scope bar), each a
/// `CPListTemplate`/`CPSearchTemplate` reading directly from
/// `LibraryStore.shared`. Selecting a track starts playback on the shared
/// `AudioPlayer` — the same engine phone playback uses — then pushes the
/// system `CPNowPlayingTemplate`.
///
/// Every list starts empty and fills in via `updateSections` once its
/// `LibraryStore` (an actor) read completes — CarPlay needs a template
/// synchronously for `setRootTemplate`/`pushTemplate`, and there is no
/// blocking-read escape hatch from an actor.
///
/// Real report: "currently I have to scroll by artist only and I have no
/// way to search for songs / albums or even list them in carplay." Before
/// this, the tab bar only had Playlists/Artists/Recently Played/Favorites —
/// no way to browse by Album or Song, and no search at all. Replaces the
/// standalone Artists tab with a "Library" tab (Artists/Albums/Songs
/// sub-menu, reusing `LibraryBrowse.sections(for:rows:)` — the exact same
/// grouping logic `MyMusicView`/`LibraryView` already use, not a second
/// implementation) and adds a "Search" tab. Both fit within Apple's 5-tab
/// cap alongside the existing Playlists/Recently Played/Favorites.
@MainActor
enum CarPlayRootBuilder {
    /// CarPlay enforces a per-template item cap (Apple's guidelines: a
    /// `CPListTemplate` should stay well under it) — a large playlist or a
    /// heavily-favorited library could otherwise silently fail to display
    /// past the cap, or push more work than a car's slower hardware should
    /// take on.
    fileprivate static let maxItemsPerList = 300

    /// `CPSearchTemplate.searchTemplateDelegate` is `weak` — this session
    /// holds the one strong reference for as long as CarPlay is connected
    /// (mirrors `CPNowPlayingTemplate.shared`'s own singleton-ish lifetime;
    /// a fresh `rootTemplate(interfaceController:)` call on reconnect
    /// replaces it).
    private static var searchDelegate: CarPlaySearchDelegate?

    static func rootTemplate(interfaceController: CPInterfaceController) -> CPTabBarTemplate {
        let search = searchTemplate(interfaceController: interfaceController)
        let tabs = [
            playlistsTemplate(interfaceController: interfaceController),
            libraryTemplate(interfaceController: interfaceController),
            search,
            flatListTemplate(
                title: "Recently Played", systemImage: "clock", interfaceController: interfaceController,
                loadRows: { try await LibraryStore.shared.recentlyPlayedRows() }),
            flatListTemplate(
                title: "Favorites", systemImage: "heart", interfaceController: interfaceController,
                loadRows: { try await LibraryStore.shared.favoriteRows() })
        ]
        return CPTabBarTemplate(templates: tabs)
    }

    // MARK: - Playlists

    private static func playlistsTemplate(interfaceController: CPInterfaceController) -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        template.tabImage = UIImage(systemName: "music.note.list")
        Task {
            let playlists = ((try? await LibraryStore.shared.allPlaylists()) ?? []).prefix(maxItemsPerList)
            let items = playlists.map { playlist -> CPListItem in
                let item = CPListItem(text: playlist.title, detailText: nil)
                item.handler = { _, completion in
                    Task {
                        let rows = Array(((try? await LibraryStore.shared.playlistItems(playlistId: playlist.id ?? -1)) ?? [])
                            .prefix(maxItemsPerList))
                        let leaf = trackListTemplate(
                            title: playlist.title, rows: rows, source: .playlist(playlist),
                            interfaceController: interfaceController)
                        interfaceController.pushTemplate(leaf, animated: true, completion: nil)
                        completion()
                    }
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
        return template
    }

    // MARK: - Library (Artists / Albums / Songs)

    /// One tab, three browse modes — mirrors the phone app's own My Music
    /// unification (one entry point, a mode picker) rather than spending a
    /// separate tab slot per mode, which Apple's 5-tab cap can't afford
    /// alongside Playlists/Search/Recently Played/Favorites.
    private static func libraryTemplate(interfaceController: CPInterfaceController) -> CPListTemplate {
        let template = CPListTemplate(title: "Library", sections: [])
        template.tabImage = UIImage(systemName: "square.grid.2x2")
        let modes: [(LibraryBrowseMode, String)] = [
            (.artists, "person.wave.2"), (.albums, "square.stack"), (.songs, "music.note")
        ]
        let items = modes.map { mode, icon -> CPListItem in
            let item = CPListItem(text: mode.rawValue, detailText: nil, image: UIImage(systemName: icon))
            item.handler = { _, completion in
                Task {
                    let rows = (try? await LibraryStore.shared.allTrackRows()) ?? []
                    let sections = LibraryBrowse.sections(for: mode, rows: rows)
                    let leaf = browseModeTemplate(mode: mode, sections: sections, interfaceController: interfaceController)
                    interfaceController.pushTemplate(leaf, animated: true, completion: nil)
                    completion()
                }
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
        return template
    }

    /// One `LibraryBrowse.Entry` per row. A `.song` entry's `rows` is
    /// already exactly the one track it represents (`LibraryBrowse
    /// .songSections`) — tapping it plays directly, using every song entry
    /// currently listed as the queue (so Next/Previous on the car's
    /// controls advances through the same list), rather than pushing a
    /// redundant single-item list the way an Artist/Album entry's
    /// multi-track group does.
    private static func browseModeTemplate(
        mode: LibraryBrowseMode, sections: [LibraryBrowse.Section], interfaceController: CPInterfaceController
    ) -> CPListTemplate {
        let allSongRows: [TrackRow]? = mode == .songs
            ? sections.flatMap(\.entries).compactMap { $0.rows.first }
            : nil
        var songIndex = 0
        let cpSections = sections.map { section -> CPListSection in
            let items = Array(section.entries.prefix(maxItemsPerList)).map { entry -> CPListItem in
                let item = CPListItem(text: entry.title, detailText: entry.subtitle)
                if entry.kind == .song, let allSongRows {
                    let startAt = songIndex
                    songIndex += 1
                    item.handler = { _, completion in
                        AudioPlayer.shared.play(tracks: allSongRows, startAt: startAt, source: .library)
                        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        completion()
                    }
                } else {
                    item.handler = { _, completion in
                        let rows = Array(entry.rows.prefix(maxItemsPerList))
                        let leaf = trackListTemplate(
                            title: entry.title, rows: rows, source: .library,
                            interfaceController: interfaceController)
                        interfaceController.pushTemplate(leaf, animated: true, completion: nil)
                        completion()
                    }
                }
                return item
            }
            return CPListSection(items: items, header: section.indexTitle, sectionIndexTitle: section.indexTitle)
        }
        return CPListTemplate(title: mode.rawValue, sections: cpSections)
    }

    // MARK: - Search

    /// `CPSearchTemplate` gets a real text field with the car's own
    /// dictation/microphone input for free at the OS level — no separate
    /// SiriKit intent handler needed for "type or speak what to search
    /// for." A true Siri Shortcut ("Hey Siri, play {song} in Platterhead"
    /// without opening the app first) is a materially different feature —
    /// it needs an `INPlayMediaIntent` handler, which this codebase does
    /// not have (checked: no Intents extension target in project.yml, no
    /// `INPlayMediaIntent`/`INPlayMediaIntentHandling` conformance anywhere
    /// under Sources/). Not attempted here — flagged as a real, separate
    /// follow-up, not silently skipped.
    private static func searchTemplate(interfaceController: CPInterfaceController) -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        let delegate = CarPlaySearchDelegate(interfaceController: interfaceController)
        searchDelegate = delegate
        template.delegate = delegate
        return template
    }

    // MARK: - Flat track lists (Recently Played / Favorites)

    private static func flatListTemplate(
        title: String, systemImage: String, interfaceController: CPInterfaceController,
        loadRows: @escaping () async throws -> [TrackRow]
    ) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabImage = UIImage(systemName: systemImage)
        Task {
            let rows = Array(((try? await loadRows()) ?? []).prefix(maxItemsPerList))
            template.updateSections([trackSection(rows: rows, source: .library, interfaceController: interfaceController)])
        }
        return template
    }

    // MARK: - Track list (shared leaf template)

    fileprivate static func trackListTemplate(
        title: String, rows: [TrackRow], source: QueueSource, interfaceController: CPInterfaceController
    ) -> CPListTemplate {
        CPListTemplate(title: title, sections: [trackSection(rows: rows, source: source, interfaceController: interfaceController)])
    }

    /// Pushes the system `CPNowPlayingTemplate` right after starting
    /// playback — real gap found auditing the first draft: this file's own
    /// doc comment claimed selecting a track "pushes the system
    /// CPNowPlayingTemplate," but nothing here actually did, leaving the
    /// driver with no visual confirmation their selection registered.
    fileprivate static func trackSection(
        rows: [TrackRow], source: QueueSource, interfaceController: CPInterfaceController
    ) -> CPListSection {
        let items = rows.enumerated().map { index, row -> CPListItem in
            let subtitle = row.artist?.name ?? row.album?.artist
            let item = CPListItem(text: row.track.title, detailText: subtitle)
            item.handler = { _, completion in
                AudioPlayer.shared.play(tracks: rows, startAt: index, source: source)
                interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                completion()
            }
            Task {
                guard let image = await ArtworkService.shared.thumbnail(forTrackRow: row, maxDimension: 128)
                else { return }
                item.setImage(image)
            }
            return item
        }
        return CPListSection(items: items)
    }
}

/// `CPSearchTemplateDelegate` is `NSObjectProtocol`-based, so this can't be
/// a nested type inside the `CarPlayRootBuilder` enum the way the other
/// helpers are — it needs a real class identity. Reuses
/// `CarPlayRootBuilder`'s `trackSection`/`trackListTemplate`/
/// `maxItemsPerList` (`fileprivate`, not `private` — this is a second type
/// in the same file) rather than duplicating that logic.
@MainActor
private final class CarPlaySearchDelegate: NSObject, CPSearchTemplateDelegate {
    private let interfaceController: CPInterfaceController

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completionHandler([])
            return
        }
        Task {
            // Reuses LibraryStore.search(_:) — the same metadata matcher
            // AppState.runSearch()/DiscoverySearchViewModel's metadata mode
            // already use — never a second, ad-hoc text matcher.
            let rows = Array(((try? await LibraryStore.shared.search(trimmed)) ?? [])
                .prefix(CarPlayRootBuilder.maxItemsPerList))
            let items = rows.enumerated().map { index, row -> CPListItem in
                let subtitle = row.artist?.name ?? row.album?.artist
                let item = CPListItem(text: row.track.title, detailText: subtitle)
                item.handler = { [weak self] _, completion in
                    guard let self else { completion(); return }
                    AudioPlayer.shared.play(tracks: rows, startAt: index, source: .library)
                    self.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    completion()
                }
                return item
            }
            completionHandler(items)
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        // The result's own `item.handler` (set above) already starts
        // playback and pushes Now Playing — nothing further to do here.
        completionHandler()
    }
}
