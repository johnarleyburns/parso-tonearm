import CarPlay
import TonearmCore

/// Builds the CarPlay template hierarchy: a tab bar mirroring the phone
/// app's most-used browse surfaces (Playlists/Artists/Recently Played/
/// Favorites — CarPlay caps a tab bar at 5 tabs, so this deliberately
/// doesn't try to mirror the full My Music scope bar), each a `CPListTemplate`
/// reading directly from `LibraryStore.shared`. Selecting a track starts
/// playback on the shared `AudioPlayer` — the same engine phone playback
/// uses — then pushes the system `CPNowPlayingTemplate`.
///
/// Every list starts empty and fills in via `updateSections` once its
/// `LibraryStore` (an actor) read completes — CarPlay needs a template
/// synchronously for `setRootTemplate`/`pushTemplate`, and there is no
/// blocking-read escape hatch from an actor.
@MainActor
enum CarPlayRootBuilder {
    /// CarPlay enforces a per-template item cap (Apple's guidelines: a
    /// `CPListTemplate` should stay well under it) — a large playlist or a
    /// heavily-favorited library could otherwise silently fail to display
    /// past the cap, or push more work than a car's slower hardware should
    /// take on.
    private static let maxItemsPerList = 300

    static func rootTemplate(interfaceController: CPInterfaceController) -> CPTabBarTemplate {
        let tabs = [
            playlistsTemplate(interfaceController: interfaceController),
            artistsTemplate(interfaceController: interfaceController),
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

    // MARK: - Artists

    private static func artistsTemplate(interfaceController: CPInterfaceController) -> CPListTemplate {
        let template = CPListTemplate(title: "Artists", sections: [])
        template.tabImage = UIImage(systemName: "person.wave.2")
        Task {
            let artists = ((try? await LibraryStore.shared.allArtists()) ?? []).prefix(maxItemsPerList)
            let items = artists.map { artist -> CPListItem in
                let item = CPListItem(text: artist.name, detailText: nil)
                item.handler = { _, completion in
                    Task {
                        let rows = Array(((try? await LibraryStore.shared.tracks(forArtist: artist.name)) ?? [])
                            .prefix(maxItemsPerList))
                        let leaf = trackListTemplate(
                            title: artist.name, rows: rows, source: .library,
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

    private static func trackListTemplate(
        title: String, rows: [TrackRow], source: QueueSource, interfaceController: CPInterfaceController
    ) -> CPListTemplate {
        CPListTemplate(title: title, sections: [trackSection(rows: rows, source: source, interfaceController: interfaceController)])
    }

    /// Pushes the system `CPNowPlayingTemplate` right after starting
    /// playback — real gap found auditing the first draft: this file's own
    /// doc comment claimed selecting a track "pushes the system
    /// CPNowPlayingTemplate," but nothing here actually did, leaving the
    /// driver with no visual confirmation their selection registered.
    private static func trackSection(
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
