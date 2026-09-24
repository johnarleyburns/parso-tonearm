#if !targetEnvironment(macCatalyst)
import CarPlay
import TonearmCore

/// Builds the CarPlay template hierarchy: a tab bar mirroring the phone
/// app's most-used browse surfaces (Playlists/Library/More), each a
/// `CPListTemplate` reading directly from `LibraryStore.shared`. Selecting a
/// track starts playback on the shared `AudioPlayer` — the same engine phone
/// playback uses — then pushes the system `CPNowPlayingTemplate`.
///
/// Every list starts empty and fills in via `updateSections` once its
/// `LibraryStore` (an actor) read completes — CarPlay needs a template
/// synchronously for `setRootTemplate`/`pushTemplate`, and there is no
/// blocking-read escape hatch from an actor.
///
/// Real report: "currently I have to scroll by artist only and I have no
/// way to search for songs / albums or even list them in carplay." Before
/// this, the tab bar only had Playlists/Artists/Recently Played/Favorites —
/// no way to browse by Album or Song. Replaces the standalone Artists tab
/// with a "Library" tab (Artists/Albums/Songs sub-menu, reusing
/// `LibraryBrowse.sections(for:rows:)` — the exact same grouping logic
/// `MyMusicView`/`LibraryView` already use, not a second implementation) —
/// its "Songs" mode is a full alphabetical list, which is the "list them"
/// half of the original report.
///
/// The "search" half was tried twice this session (a `CPSearchTemplate`
/// pushed from a dedicated tab, then the same thing after popping to root
/// first) and crashed on real hardware both times — root cause found only
/// by reading Apple's own CarPlay App Programming Guide PDF directly
/// (developer.apple.com/carplay/documentation/CarPlay-App-Programming-
/// Guide.pdf, the template-support matrix, "Templates" section): Search is
/// simply **not in the supported-template set for the Audio/video app
/// category at all** — not a stack-ordering bug, not a push-vs-present bug,
/// a hard per-category platform restriction with no workaround. `Now
/// playing`, `List`, `Tab bar`, `Alert`/`Action sheet` ARE all supported for
/// Audio; `Search` and `Point of interest` are not. Removed the Search tab
/// entirely rather than keep shipping something Apple's own platform can
/// never let work — a real, honest capability gap, not a bug to chase
/// further. A true "search while driving" story for an Audio-category app
/// would need Siri's `INPlayMediaIntent` (a separate Intents extension this
/// app doesn't have — flagged as a real, distinct follow-up), not
/// `CPSearchTemplate`.
///
/// Separately, `CPTabBarTemplate.maximumTabCount` (Apple's
/// `CPTabBarTemplate.h`) is NOT a fixed "5" either — it depends on the app's
/// CarPlay entitlement category — so `rootTemplate` still caps defensively
/// at that real, queried value even though only 3 tabs are built today.
@MainActor
enum CarPlayRootBuilder {
    /// CarPlay enforces a per-template item cap (Apple's guidelines: a
    /// `CPListTemplate` should stay well under it) — a large playlist or a
    /// heavily-favorited library could otherwise silently fail to display
    /// past the cap, or push more work than a car's slower hardware should
    /// take on.
    fileprivate static let maxItemsPerList = 300

    static func rootTemplate(interfaceController: CPInterfaceController) -> CPTabBarTemplate {
        let tabs = [
            playlistsTemplate(interfaceController: interfaceController),
            libraryTemplate(interfaceController: interfaceController),
            moreTemplate(interfaceController: interfaceController)
        ]
        // Real, repeated crash (4 TestFlight reports, confirmed via Apple's
        // own CPTabBarTemplate.h): `initWithTemplates:` throws when the
        // array exceeds `maximumTabCount` — which is NOT the fixed "5" this
        // file used to assume, but depends on the app's CarPlay entitlement
        // category and can change per-OS/per-device. `tabs.count` above (4)
        // was chosen to fit comfortably under what a plain CarPlay-audio
        // entitlement grants, but trim defensively rather than ever crash
        // again if a future change (more tabs added, a stricter OS) pushes
        // past whatever the real limit turns out to be on a given device.
        let capped = Array(tabs.prefix(CPTabBarTemplate.maximumTabCount))
        return CPTabBarTemplate(templates: capped)
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
    /// separate tab slot per mode, which the real, entitlement-dependent tab
    /// cap can't afford alongside Playlists/More.
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

    // MARK: - More (Recently Played / Favorites)

    /// One tab, two picks — same reasoning as `libraryTemplate`'s mode
    /// picker: keeps Recently Played and Favorites off Playlists/Library's
    /// own tab budget rather than spending a slot each.
    private static func moreTemplate(interfaceController: CPInterfaceController) -> CPListTemplate {
        let template = CPListTemplate(title: "More", sections: [])
        template.tabImage = UIImage(systemName: "ellipsis")
        let picks: [(title: String, icon: String, loadRows: @Sendable () async throws -> [TrackRow])] = [
            ("Recently Played", "clock", { try await LibraryStore.shared.recentlyPlayedRows() }),
            ("Favorites", "heart", { try await LibraryStore.shared.favoriteRows() })
        ]
        let items = picks.map { pick -> CPListItem in
            let item = CPListItem(text: pick.title, detailText: nil, image: UIImage(systemName: pick.icon))
            item.handler = { _, completion in
                Task {
                    let rows = Array(((try? await pick.loadRows()) ?? []).prefix(maxItemsPerList))
                    let leaf = trackListTemplate(
                        title: pick.title, rows: rows, source: .library,
                        interfaceController: interfaceController)
                    interfaceController.pushTemplate(leaf, animated: true, completion: nil)
                    completion()
                }
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
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
#endif
