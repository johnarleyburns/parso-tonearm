import SwiftUI
import WatchKit
import TonearmWatchCore
import TonearmWatchProtocol

// Watch redesign §5 B1–B3 / T1–T2 — browse and play. Inset-grouped lists with artwork, one line of
// metadata, and one glyph saying where a song plays. Every play control names its destination.

// MARK: - Index lists (B1)

/// Playlists on this watch (offline scope).
struct WatchPlaylistsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                WatchEmptyStateView(icon: "music.note.list", title: "No Playlists on This Watch",
                                    message: "Download a playlist from Platterhead on your iPhone to play it here.")
            } else {
                List(model.playlists) { playlist in
                    NavigationLink(value: WatchNav.playlist(playlist.id)) {
                        WatchCollectionRowLabel(title: playlist.title,
                                                detail: String(localized: "\(playlist.readyTrackIDs.count) songs"),
                                                tintKey: playlist.title, fullyOnWatch: true)
                    }
                    .watchCardRow()
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .task { await model.refresh() }
    }
}

/// Albums assembled from the songs on this watch (offline scope).
struct WatchAlbumsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        Group {
            if model.albums.isEmpty {
                WatchEmptyStateView(icon: "square.stack", title: "No Albums on This Watch",
                                    message: "Albums appear here as their songs download.")
            } else {
                List(model.albums) { album in
                    NavigationLink(value: WatchNav.album(album.id)) {
                        WatchCollectionRowLabel(title: album.title,
                                                detail: album.artist ?? String(localized: "\(album.trackIDs.count) songs"),
                                                tintKey: album.title, fullyOnWatch: true,
                                                artworkFilename: firstArtwork(album))
                    }
                    .watchCardRow()
                    .accessibilityIdentifier("watch.album.\(album.id)")
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Albums")
        .task { await model.refresh() }
    }

    private func firstArtwork(_ album: WatchAlbumGroup) -> String? {
        album.trackIDs.lazy.compactMap { model.track(id: $0)?.artworkFilename }.first
    }
}

/// The iPhone library's playlists or albums (connected scope), with how much is on the watch.
struct WatchPhoneIndexView: View {
    let category: WatchBrowseCategory

    @ObservedObject private var model = WatchAppAssembly.shared.model
    @State private var rows: [WatchResultRow] = []
    @State private var nextPage: String?
    @State private var phase: Phase = .loading

    private enum Phase { case loading, loaded, failed }

    var body: some View {
        List {
            switch phase {
            case .loading:
                HStack { ProgressView(); Text("Loading from iPhone…").font(.caption2) }
                    .listRowBackground(Color.clear)
            case .failed:
                WatchProblemCard(systemImage: "iphone.slash", title: "Couldn't Reach iPhone",
                                 message: String(localized: "Keep your iPhone nearby, or browse what's on this watch."),
                                 actions: [.init(title: "Try Again", identifier: "watch.browse.retry") {
                                     Task { await load(reset: true) }
                                 }])
                .listRowBackground(Color.clear)
            case .loaded where rows.isEmpty:
                WatchEmptyStateView(icon: category == .albums ? "square.stack" : "music.note.list",
                                    title: category == .albums ? "No Albums" : "No Playlists",
                                    message: "Your iPhone library has none yet.")
            case .loaded:
                ForEach(rows) { row in
                    if let ref = row.collectionRef {
                        NavigationLink(value: ref.kind == .playlist ? WatchNav.playlist(ref.id) : WatchNav.album(ref.id)) {
                            WatchCollectionRowLabel(title: row.title, detail: detail(for: row, ref: ref),
                                                    tintKey: row.title, fullyOnWatch: isFullyOnWatch(row, ref: ref))
                        }
                        .watchCardRow()
                    }
                }
                if nextPage != nil {
                    Button { Task { await load(reset: false) } } label: { Text("Show More") }
                        .buttonStyle(.watchSecondarySmall)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(category == .albums ? Text("Albums") : Text("Playlists"))
        .task { if rows.isEmpty { await load(reset: true) } }
    }

    private func load(reset: Bool) async {
        if reset { phase = .loading }
        let page = await WatchAppAssembly.shared.browsePhone(category, pageToken: reset ? nil : nextPage)
        guard let page else { if reset { phase = .failed }; return }
        rows = reset ? page.rows : rows + page.rows
        nextPage = page.nextPageToken
        phase = .loaded
    }

    private func onWatchCount(_ ref: WatchCollectionRef) -> Int {
        ref.kind == .playlist ? (model.playlist(id: ref.id)?.readyTrackIDs.count ?? 0) : 0
    }

    private func detail(for row: WatchResultRow, ref: WatchCollectionRef) -> String {
        let total = row.trackCount
        let local = onWatchCount(ref)
        switch (total, local) {
        case let (total?, local) where local >= total && total > 0:
            return String(localized: "\(total) songs · all on watch")
        case let (total?, local) where local > 0:
            return String(localized: "\(total) songs · \(local) on watch")
        case let (total?, _):
            return String(localized: "\(total) songs")
        default:
            return row.subtitle ?? ""
        }
    }

    private func isFullyOnWatch(_ row: WatchResultRow, ref: WatchCollectionRef) -> Bool {
        guard let total = row.trackCount, total > 0 else { return false }
        return onWatchCount(ref) >= total
    }
}

/// Every song on this watch.
struct WatchSongsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        Group {
            if model.tracks.isEmpty {
                WatchEmptyStateView(icon: "music.note", title: "No Songs on This Watch",
                                    message: "Songs you download from your iPhone appear here.")
            } else {
                WatchCollectionDetailView(source: .localSongs)
            }
        }
        .navigationTitle("Songs")
    }
}

// MARK: - Collection detail (T1 header + B2 rows + B3 menu)

enum WatchCollectionSource: Hashable {
    case phone(WatchCollectionRef)
    case localPlaylist(String)
    case localAlbum(String)
    case localSongs
}

/// Wrappers kept for the existing navigation destinations.
struct WatchPlaylistDetailView: View {
    let playlistID: String
    var body: some View { WatchCollectionDetailView(source: .localPlaylist(playlistID)) }
}

struct WatchAlbumDetailView: View {
    let albumID: String
    var body: some View { WatchCollectionDetailView(source: .localAlbum(albumID)) }
}

struct WatchPhoneCollectionView: View {
    let ref: WatchCollectionRef
    var body: some View { WatchCollectionDetailView(source: .phone(ref)) }
}

struct WatchCollectionDetailView: View {
    let source: WatchCollectionSource

    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @State private var phoneTracks: [WatchTrackSummary] = []
    @State private var phoneTitle: String?
    @State private var phoneTotal = 0
    @State private var nextPage: String?
    @State private var phoneState: PhoneLoad = .idle
    @State private var choice: PendingPlay?
    @State private var requestedDownloads: Set<String> = []

    private enum PhoneLoad { case idle, loading, loaded, failed }

    /// A song as this screen shows it, whichever side it came from.
    struct Song: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let duration: Double?
        let albumTitle: String
        let artworkFilename: String?
        let local: WatchTrackSnapshot?
        var isOnWatch: Bool { local != nil }
    }

    /// A play the user asked for that needs the one-time target choice first (T2).
    struct PendingPlay: Identifiable {
        let id = UUID()
        let title: String
        let startID: String?
        let shuffled: Bool
    }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
            if phoneState == .loading && songs.isEmpty {
                HStack { ProgressView(); Text("Loading from iPhone…").font(.caption2) }
                    .listRowBackground(Color.clear)
            } else if phoneState == .failed && songs.isEmpty {
                WatchProblemCard(systemImage: "iphone.slash", title: "Couldn't Reach iPhone",
                                 message: String(localized: "This list lives on your iPhone. Keep it nearby and try again."),
                                 actions: [.init(title: "Try Again", identifier: "watch.collection.retry") {
                                     Task { await loadPhone(reset: true) }
                                 }])
                .listRowBackground(Color.clear)
            }
            ForEach(songs) { song in
                songRow(song)
            }
            if nextPage != nil {
                Button { Task { await loadPhone(reset: false) } } label: {
                    Text("Show More (\(songs.count) of \(phoneTotal))")
                }
                .buttonStyle(.watchSecondarySmall)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(title))
        .task {
            await model.refresh()
            if phoneRef(for: source) != nil, case .phone = source, phoneTracks.isEmpty { await loadPhone(reset: true) }
        }
        .sheet(item: $choice) { pending in
            WatchTargetChoiceView(
                itemTitle: pending.title,
                phoneDetail: canPlayOnPhone ? String(localized: "Speakers or its headphones") : nil,
                watchDetail: watchDetailForChoice(pending)) { target in
                    choice = nil
                    coordinator.setTarget(target)
                    perform(target: target, startID: pending.startID, shuffled: pending.shuffled)
                }
        }
    }

    // MARK: Data

    private var title: String {
        switch source {
        case .phone: phoneTitle ?? String(localized: "Collection")
        case .localPlaylist(let id): model.playlist(id: id)?.title ?? String(localized: "Playlist")
        case .localAlbum(let id): model.album(id: id)?.title ?? String(localized: "Album")
        case .localSongs: String(localized: "Songs")
        }
    }

    private var songs: [Song] {
        switch source {
        case .phone:
            return phoneTracks.map { item in
                let local = model.track(id: item.trackID.rawValue)
                return Song(id: item.trackID.rawValue, title: item.title, artist: item.artist,
                            duration: item.durationSeconds, albumTitle: item.albumTitle,
                            artworkFilename: local?.artworkFilename, local: local)
            }
        case .localPlaylist(let id):
            let ids = model.playlist(id: id)?.trackIDs ?? []
            return ids.compactMap { model.track(id: $0) }.map(Self.song)
        case .localAlbum(let id):
            return model.readyTracks(forAlbum: id).map(Self.song)
        case .localSongs:
            return model.tracks.filter(\.isReady).map(Self.song)
        }
    }

    private static func song(_ track: WatchTrackSnapshot) -> Song {
        Song(id: track.id, title: track.title, artist: track.artist, duration: track.durationSeconds,
             albumTitle: track.albumTitle, artworkFilename: track.artworkFilename, local: track)
    }

    private var localTracks: [WatchTrackSnapshot] { songs.compactMap(\.local).filter(\.isReady) }

    /// The phone-side collection this screen can address, if any. A local playlist exists on the
    /// phone under the same id; a derived local album or "all songs" has no phone twin.
    private func phoneRef(for source: WatchCollectionSource) -> WatchCollectionRef? {
        switch source {
        case .phone(let ref): ref
        case .localPlaylist(let id): WatchCollectionRef(kind: .playlist, id: id)
        case .localAlbum, .localSongs: nil
        }
    }

    private var canPlayOnPhone: Bool { false }
    private var canPlayOnWatch: Bool { !localTracks.isEmpty }

    /// The remembered target when the user has chosen one; otherwise `nil` (ask once, T2).
    private var rememberedTarget: WatchTarget? {
        WatchPlaybackTargetStore.hasStoredPreference() ? coordinator.target : nil
    }

    /// The primary target for this screen: the only possible one, else the remembered one.
    private var primaryTarget: WatchTarget? {
        canPlayOnWatch ? .thisWatch : nil
    }

    // MARK: Header (T1)

    @ViewBuilder
    private var header: some View {
        if !songs.isEmpty || canPlayOnPhone {
            VStack(spacing: 6) {
                primaryButton
                HStack(spacing: 6) {
                    Button { play(startID: nil, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.watchSecondarySmall)
                    .accessibilityIdentifier("watch.collection.shuffle")
                    secondaryTargetButton
                }
                if chrome.showsConnectedFeatures, case .phone = source, phoneTotal > 0 {
                    Text(onWatchSummary)
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch primaryTarget {
        case .iPhone?:
            Button { perform(target: .iPhone, startID: nil, shuffled: false) } label: {
                Label("Play on iPhone", systemImage: "play.fill")
            }
            .buttonStyle(.watchPrimary)
            .accessibilityIdentifier("watch.collection.playPhone")
        case .thisWatch?:
            Button { perform(target: .thisWatch, startID: nil, shuffled: false) } label: {
                if chrome.showsConnectedFeatures {
                    Label("Play on Watch", systemImage: "play.fill")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(.watchPrimary)
            .accessibilityIdentifier("watch.collection.playLocal")
        case nil:
            Button { play(startID: nil, shuffled: false) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.watchPrimary)
            .disabled(!canPlayOnPhone && !canPlayOnWatch)
            .accessibilityIdentifier("watch.collection.play")
        }
    }

    @ViewBuilder
    private var secondaryTargetButton: some View {
        switch primaryTarget {
        case .iPhone? where canPlayOnWatch:
            Button { perform(target: .thisWatch, startID: nil, shuffled: false) } label: {
                Label("On Watch", systemImage: "applewatch")
            }
            .buttonStyle(.watchSecondarySmall)
            .accessibilityIdentifier("watch.collection.playLocal")
        case .thisWatch? where canPlayOnPhone:
            Button { perform(target: .iPhone, startID: nil, shuffled: false) } label: {
                Label("On iPhone", systemImage: "iphone")
            }
            .buttonStyle(.watchSecondarySmall)
            .accessibilityIdentifier("watch.collection.playPhone")
        default:
            EmptyView()
        }
    }

    private var onWatchSummary: String {
        let local = localTracks.count
        if local == 0 { return String(localized: "None of these songs are on this watch") }
        if local >= phoneTotal { return String(localized: "All \(phoneTotal) songs are on this watch") }
        return String(localized: "\(local) of \(phoneTotal) songs are on this watch")
    }

    // MARK: Rows (B2/B3)

    private func songRow(_ song: Song) -> some View {
        let playableHere = isPlayable(song)
        return Button {
            play(startID: song.id, shuffled: false)
        } label: {
            HStack(spacing: 8) {
                WatchLocalArtTile(filename: song.artworkFilename, tintKey: song.albumTitle.isEmpty ? song.title : song.albumTitle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.body).lineLimit(1)
                    Text(rowDetail(song)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                locationGlyph(song)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playableHere)
        .opacity(playableHere ? 1 : 0.45)
        .watchCardRow()
        .accessibilityIdentifier("watch.track.\(song.id)")
        .accessibilityHint(playableHere ? Text(verbatim: "") : Text("Only on your iPhone"))
        // B3: swipe for the per-song actions (`contextMenu` is deprecated on watchOS).
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { menu(for: song) }
    }

    private func rowDetail(_ song: Song) -> String {
        var parts: [String] = []
        if !song.artist.isEmpty { parts.append(song.artist) }
        if !song.isOnWatch { parts.append(String(localized: "Not downloaded to this watch")) }
        else if let duration = song.duration { parts.append(WatchTimeFmt.mmss(duration)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func locationGlyph(_ song: Song) -> some View {
        if requestedDownloads.contains(song.id), !song.isOnWatch {
            WatchTransferRing(fraction: model.transferFraction(forTrackID: song.id), size: 16)
        } else if song.isOnWatch && effectiveTarget != .thisWatch {
            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(WatchPalette.success)
                .accessibilityLabel(Text("On this watch"))
        } else if !song.isOnWatch {
            Image(systemName: "arrow.down.circle").font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel(Text("Available to download"))
        }
    }

    @ViewBuilder
    private func menu(for song: Song) -> some View {
        if song.isOnWatch {
            Button { perform(target: .thisWatch, startID: song.id, shuffled: false) } label: {
                Label("Play on Watch", systemImage: "applewatch")
            }
            .tint(WatchPalette.accent)
        }
        if !song.albumTitle.isEmpty, model.album(id: song.albumTitle) != nil {
            NavigationLink(value: WatchNav.album(song.albumTitle)) {
                Label("Go to Album", systemImage: "square.stack")
            }
            .tint(.gray)
        }
    }

    /// The target a row tap uses when it doesn't have to ask.
    private var effectiveTarget: WatchTarget? { primaryTarget }

    private func isPlayable(_ song: Song) -> Bool {
        switch effectiveTarget {
        case .thisWatch?: song.isOnWatch
        case .iPhone?, nil: false
        }
    }

    // MARK: Play

    private func play(startID: String?, shuffled: Bool) {
        if let target = primaryTarget {
            perform(target: target, startID: startID, shuffled: shuffled)
        } else {
            let name = startID.flatMap { id in songs.first { $0.id == id }?.title } ?? title
            choice = PendingPlay(title: name, startID: startID, shuffled: shuffled)
        }
    }

    private func perform(target: WatchTarget, startID: String?, shuffled: Bool) {
        WKInterfaceDevice.current().play(.click)
        switch target {
        case .iPhone:
            return
        case .thisWatch:
            var tracks = localTracks
            guard !tracks.isEmpty else { return }
            if shuffled { tracks.shuffle() }
            let start = startID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
            WatchPlayer.shared.play(tracks: tracks, startAt: start)
        }
    }

    private func watchDetailForChoice(_ pending: PendingPlay) -> String? {
        guard canPlayOnWatch else { return nil }
        if let id = pending.startID, songs.first(where: { $0.id == id })?.isOnWatch == false { return nil }
        if let output = WatchPlayer.shared.outputName { return String(localized: "\(output) · downloaded") }
        return String(localized: "Downloaded")
    }

    // MARK: Phone paging

    private func loadPhone(reset: Bool) async {
        guard case .phone(let ref) = source else { return }
        if reset { phoneState = .loading }
        guard let response = await WatchAppAssembly.shared.loadPhoneCollection(ref, pageToken: reset ? nil : nextPage) else {
            if reset { phoneState = .failed }
            return
        }
        phoneTitle = response.title
        phoneTotal = response.totalCount
        phoneTracks = reset ? response.tracks : phoneTracks + response.tracks
        nextPage = response.nextPageToken
        phoneState = .loaded
    }
}

// MARK: - T2 target choice

/// Asked once, the first time an item both targets can play is played with no stored preference.
/// A row that can't play says why instead of disappearing.
struct WatchTargetChoiceView: View {
    let itemTitle: String
    let phoneDetail: String?
    let watchDetail: String?
    let choose: (WatchTarget) -> Void

    var body: some View {
        List {
            Button { choose(.iPhone) } label: {
                choiceRow(systemImage: "iphone", title: "iPhone",
                          detail: phoneDetail ?? String(localized: "iPhone isn't reachable"))
            }
            .disabled(phoneDetail == nil)
            .accessibilityIdentifier("watch.choice.iPhone")
            Button { choose(.thisWatch) } label: {
                choiceRow(systemImage: "applewatch", title: "Apple Watch",
                          detail: watchDetail ?? String(localized: "Not downloaded"))
            }
            .disabled(watchDetail == nil)
            .accessibilityIdentifier("watch.choice.watch")
            Text("Asked once. Change any time in Now Playing › More.")
                .font(.caption2).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        .navigationTitle(Text("Play “\(itemTitle)”"))
    }

    private func choiceRow(systemImage: String, title: LocalizedStringKey, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Shared row pieces

struct WatchCollectionRowLabel: View {
    let title: String
    let detail: String
    let tintKey: String
    var fullyOnWatch = false
    var artworkFilename: String?

    var body: some View {
        HStack(spacing: 8) {
            WatchLocalArtTile(filename: artworkFilename, tintKey: tintKey, size: 32,
                              systemImage: "music.note.list")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if fullyOnWatch {
                Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(WatchPalette.success)
                    .accessibilityLabel(Text("On this watch"))
            }
        }
        .padding(.vertical, 2)
    }
}

/// An `ArtTile` for a local track's synced artwork file, loaded off the main thread and cached.
struct WatchLocalArtTile: View {
    let filename: String?
    let tintKey: String
    var size: CGFloat = 28
    var systemImage = "music.note"
    @State private var image: UIImage?

    var body: some View {
        WatchArtTile(image: image, tint: WatchArtTint.color(for: tintKey), size: size, systemImage: systemImage)
            .task(id: filename) {
                guard let filename, let directory = WatchAppAssembly.shared.artworkDirectory else { return }
                image = await WatchArtworkThumbnails.shared.thumbnail(filename: filename, directory: directory)
            }
    }
}

/// Small in-memory thumbnail cache for list artwork.
actor WatchArtworkThumbnails {
    static let shared = WatchArtworkThumbnails()
    private var cache: [String: UIImage] = [:]

    func thumbnail(filename: String, directory: URL) -> UIImage? {
        if let hit = cache[filename] { return hit }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              let image = UIImage(data: data) else { return nil }
        let thumb = Self.downscaled(image, side: 76) ?? image
        if cache.count > 200 { cache.removeAll() }
        cache[filename] = thumb
        return thumb
    }

    /// Core Graphics downscale (`preparingThumbnail` is unavailable on watchOS).
    private static func downscaled(_ image: UIImage, side: Int) -> UIImage? {
        guard let cg = image.cgImage,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = max(CGFloat(side) / CGFloat(cg.width), CGFloat(side) / CGFloat(cg.height))
        let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let origin = CGPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2)
        context.draw(cg, in: CGRect(origin: origin, size: size))
        return context.makeImage().map { UIImage(cgImage: $0) }
    }
}

extension View {
    /// The inset card row used by every redesigned list.
    func watchCardRow(current: Bool = false) -> some View {
        listRowBackground(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(current ? WatchPalette.accentSoft : WatchPalette.surface))
    }
}
