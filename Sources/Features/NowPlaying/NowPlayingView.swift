import SwiftUI
import UIKit
import PhotosUI
import TonearmCore

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var invalidation = ArtworkInvalidation.shared
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var npArtwork: UIImage?
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showEQ = false
    @State private var showArtworkDeleteAlert = false
    @State private var showAddToPlaylist = false
    /// Track key whose watch transfer we toasted the *start* of, so we can toast its completion
    /// when it lands in the watch manifest.
    @State private var pendingWatchToastTrackID: String?

    var body: some View {
        ZStack {
            npBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 5).padding(.top, 8)

                ArtworkView(
                    image: npArtwork,
                    trackRow: player.currentTrack,
                    seed: player.currentTrack?.album?.title ?? "np",
                    cornerRadius: 16
                )
                .frame(maxWidth: 360)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                .padding(.top, 22)
                .overlay {
                    if player.isAmbient, let channelId = player.ambientChannelId,
                       let videoURL = BuiltInContentProvider.bundledVideoURL(forChannelId: channelId) {
                        LoopingVideoView(url: videoURL, isPlaying: player.isPlaying)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .contextMenu {
                    if !player.isAmbient, player.currentTrack != nil {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Change Artwork", systemImage: "photo.badge.plus")
                        }
                        if npArtwork != nil {
                            Button(role: .destructive) {
                                showArtworkDeleteAlert = true
                            } label: {
                                Label("Remove Artwork", systemImage: "trash")
                            }
                        }
                    }
                }

                meta.padding(.top, 22)
                if !player.isAmbient {
                    scrubber.padding(.top, 20)
                }
                transport.padding(.top, 16)
                toolbar.padding(.top, 16)
                UpNextView()
                    .padding(.top, 20)
            }
            .padding(.horizontal, 24)
            .foregroundStyle(.white)
        }
        .presentationDragIndicator(.hidden)
        .task(id: player.currentTrack?.id) {
            guard let row = player.currentTrack else { return }
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .sheet(isPresented: $showEQ) { EQView() }
        .onChange(of: invalidation.version) { _, _ in
            Task {
                guard var row = player.currentTrack else { return }
                if row.id < 0, let persisted = await appState.persistRemoteTrack(row) { row = persisted }
                npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistDialog(title: "Add to playlist", subtitle: nil) { target in
                guard var row = player.currentTrack else { return }
                let playlist: Playlist?
                switch target {
                case .existing(let existing): playlist = existing
                case .create(let name): playlist = await appState.makePlaylist(title: name)
                }
                if row.id < 0 {
                    guard let persisted = await appState.persistRemoteTrack(row) else { return }
                    row = persisted
                }
                if let playlist { await appState.addToPlaylist(row, playlist: playlist) }
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let artworkId = await ArtworkStore.shared.store(data),
                      let row = player.currentTrack else { return }
                try? await appState.store.setCustomArtwork(trackId: row.id, artworkId: artworkId)
                npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
                ArtworkInvalidation.shared.invalidate()
                selectedPhotoItem = nil
            }
        }
        .alert("Remove Artwork", isPresented: $showArtworkDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { deleteArtwork() }
        } message: {
            Text("This will remove the custom artwork for this track.")
        }
        .onChange(of: appState.watchInstalledTrackIDs) { _, installed in
            guard let pending = pendingWatchToastTrackID, installed.contains(pending) else { return }
            pendingWatchToastTrackID = nil
            ToastCenter.shared.success("On Apple Watch", icon: "applewatch", tag: "dl.watch")
        }
        .onChange(of: appState.watchFailedCount) { old, new in
            guard new > old, pendingWatchToastTrackID != nil else { return }
            pendingWatchToastTrackID = nil
            ToastCenter.shared.error("Apple Watch download failed", icon: "applewatch.slash", tag: "dl.watch")
        }
    }

    private func deleteArtwork() {
        guard let row = player.currentTrack else { return }
        Task {
            if let artworkId = try? await appState.store.customArtworkId(for: row.id) {
                await ArtworkStore.shared.delete(id: artworkId)
            }
            try? await appState.store.deleteCustomArtwork(trackId: row.id)
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
            ArtworkInvalidation.shared.invalidate()
        }
    }

    private var npBackground: some View {
        LinearGradient(stops: [
            .init(color: Color(hex: 0x8A5A24), location: 0),
            .init(color: Color(hex: 0x59391A), location: 0.34),
            .init(color: Color(hex: 0x241708), location: 0.78),
            .init(color: Color(hex: 0x120B05), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var meta: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.track.title ?? "Nothing playing")
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(player.currentTrack.flatMap { $0.album?.artist ?? $0.artist?.name } ?? "")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
        }
    }

    private var scrubber: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let w = geo.size.width
                let playedFrac = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(Color.white.opacity(0.30))
                        .frame(width: w * player.cachedFraction)
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: w * (isScrubbing ? scrubValue : playedFrac))
                }
                .frame(height: 7)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            isScrubbing = true
                            scrubValue = max(0, min(1, v.location.x / w))
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue * player.duration)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 7)

            HStack {
                Text(TimeFmt.mmss(player.currentTime))
                    .accessibilityIdentifier("np.elapsed")
                Spacer()
                Text(qualityChip)
                    .font(.system(size: 9.5, weight: .bold)).kerning(0.8)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.3)))
                Spacer()
                Text("-" + TimeFmt.mmss(max(0, player.duration - player.currentTime)))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .monospacedDigit()
        }
    }

    private var qualityChip: String {
        if player.isAmbient { return "WAV · built-in" }
        let codec = player.currentTrack?.track.codec ?? "AUDIO"
        if player.currentTrack?.asset?.kind == .remote {
            return "\(codec) · ● \(player.cachePercent)% CACHED"
        }
        return codec
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 20))
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Previous Track")
            .accessibilityIdentifier("np.prev")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                    .frame(width: 66, height: 66).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("np.playpause")
            .accessibilityValue(player.isPlaying ? "playing" : "paused")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 20))
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Next Track")
            .accessibilityIdentifier("np.next")
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon).font(.system(size: 17))
                    .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Repeat")
            .accessibilityIdentifier("np.repeat")
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle").font(.system(size: 17))
                    .foregroundStyle(player.shuffle ? Palette.brass : .white.opacity(0.6))
                    .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.isAmbient)
            .accessibilityLabel("Shuffle")
            .accessibilityIdentifier("np.shuffle")
        }
        .foregroundStyle(.white)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                if let row = player.currentTrack { Task { await appState.toggleFavorite(row) } }
            } label: {
                Image(systemName: player.currentTrack.map { appState.isFavorite($0) } == true ? "heart.fill" : "heart")
                    .foregroundStyle(player.currentTrack.map { appState.isFavorite($0) } == true ? Color.red : .white.opacity(0.6))
                    .font(.system(size: 16)).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.currentTrack == nil)
            .accessibilityLabel("Favorite")
            .accessibilityIdentifier("np.favorite")

            Button { showAddToPlaylist = true } label: {
                Image(systemName: "text.badge.plus").font(.system(size: 16))
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.currentTrack == nil || player.isAmbient)
            .accessibilityLabel("Add to Playlist")
            .accessibilityIdentifier("np.addToPlaylist")

            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("np.airplay")

            phoneDownloadButton(for: player.currentTrack)
            watchButton(for: player.currentTrack)

            Menu {
                if !player.isAmbient, player.currentTrack != nil {
                    Button { showPhotoPicker = true } label: { Label("Change Artwork", systemImage: "photo.badge.plus") }
                    if npArtwork != nil { Button(role: .destructive) { showArtworkDeleteAlert = true } label: { Label("Remove Artwork", systemImage: "trash") } }
                }
                Button { showEQ = true } label: { Label("Equalizer", systemImage: "slider.vertical.3") }
                if let row = player.currentTrack, let shareURL = shareURL(for: row) {
                    ShareLink(item: shareURL) { Label("Share Artwork", systemImage: "square.and.arrow.up") }
                }
                Button("15 minutes") { startSleepTimer(minutes: 15) }
                Button("30 minutes") { startSleepTimer(minutes: 30) }
                Button("45 minutes") { startSleepTimer(minutes: 45) }
                Button("1 hour") { startSleepTimer(minutes: 60) }
                Button("End of track") { setSleepAtEndOfTrack(true) }
                if player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack {
                    Divider()
                    Button("Cancel Timer", role: .destructive) { cancelSleep() }
                }
            } label: {
                Image(systemName: player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 16))
                    .foregroundStyle((player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack) ? Palette.brass : .white.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("np.overflow")
        }
    }

    @ViewBuilder
    private func phoneDownloadButton(for row: TrackRow?) -> some View {
        let _ = appState.downloadRevision
        let state = row.map { appState.phoneDownloadState(for: $0) } ?? .notDownloaded
        Button {
            switch state {
            case .notDownloaded:
                if let row {
                    ToastCenter.shared.progress("Downloading…", tag: "dl.phone")
                    Task {
                        let added = await appState.download(rows: [row])
                        ToastCenter.shared.success(added > 0 ? "Saved to iPhone" : "Already saved",
                                                   tag: "dl.phone")
                    }
                }
            case .downloaded:
                if let row {
                    Task {
                        await appState.removeDownloadFromPhone(rows: [row])
                        ToastCenter.shared.info("Removed download")
                    }
                }
            case .downloading:
                break
            }
        } label: {
            downloadGlyph(for: row, fallback: state)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("np.download")
        .disabled(row == nil)
    }

    /// The cache ring. While a download is in flight, re-sample the fraction a couple of times a
    /// second (via `TimelineView`) so the ring visibly closes — nothing bumps a `@Published` while
    /// `cachedBytes` grows.
    @ViewBuilder
    private func downloadGlyph(for row: TrackRow?, fallback: PhoneDownloadState) -> some View {
        Group {
            if case .downloading = fallback, let row {
                TimelineView(.periodic(from: .now, by: 0.6)) { _ in
                    CacheGlyph(state: cacheGlyphState(from: appState.phoneDownloadState(for: row)))
                }
            } else {
                CacheGlyph(state: cacheGlyphState(from: fallback))
            }
        }
        .frame(width: 45, height: 45)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
    }

    @ViewBuilder
    private func watchButton(for row: TrackRow?) -> some View {
        let state = row.map { appState.watchGlyphState(for: $0) } ?? .notOnWatch
        Button {
            switch state {
            case .notOnWatch, .failed:
                if let row {
                    pendingWatchToastTrackID = PhoneWatchID.track(row.track).rawValue
                    ToastCenter.shared.progress("Sending to Apple Watch…", icon: "applewatch",
                                                tag: "dl.watch")
                    Task { await appState.downloadToWatch(rows: [row]) }
                }
            case .onWatch:
                if let row {
                    Task {
                        await appState.removeFromWatch(rows: [row])
                        ToastCenter.shared.info("Removed from Apple Watch", icon: "applewatch")
                    }
                }
            case .transferring:
                break
            }
        } label: {
            watchGlyph(for: row, fallback: state)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("np.watchDownload")
        .disabled(row == nil)
    }

    /// While a transfer to the watch is in flight, re-sample the sender-side byte fraction a couple
    /// of times a second so `WatchGlyphView`'s ring closes.
    @ViewBuilder
    private func watchGlyph(for row: TrackRow?, fallback: WatchGlyphState) -> some View {
        Group {
            if case .transferring = fallback, let row {
                TimelineView(.periodic(from: .now, by: 0.6)) { _ in
                    WatchGlyphView(state: appState.watchGlyphState(for: row))
                }
            } else {
                WatchGlyphView(state: fallback)
            }
        }
        .frame(width: 45, height: 45)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
    }

    private func cacheGlyphState(from state: PhoneDownloadState) -> CacheGlyphState {
        switch state {
        case .notDownloaded: return .none
        case .downloaded: return .cached
        case .downloading(let progress): return .filling(progress ?? 0.05)
        }
    }

    private func shareURL(for row: TrackRow) -> URL? {
        if let id = row.album?.artworkId, !id.isEmpty {
            return ShareURLBuilder.url(identifier: id)
        }
        return nil
    }

    // MARK: - Sleep timer

    private func startSleepTimer(minutes: Int) {
        player.applySleepTimer(.minutes(minutes))
    }

    private func setSleepAtEndOfTrack(_ on: Bool) {
        player.applySleepTimer(on ? .endOfTrack : .cancel)
    }

    private func cancelSleep() {
        player.applySleepTimer(.cancel)
    }
}
