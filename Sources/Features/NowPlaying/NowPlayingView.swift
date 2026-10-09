import SwiftUI
#if !os(macOS)
import UIKit
#endif
import TonearmCore

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var invalidation = ArtworkInvalidation.shared
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var npArtwork: PlatformImage?
    @State private var showPhotoPicker = false
    @State private var showEQ = false
    @State private var showArtworkDeleteAlert = false
    @State private var showAddToPlaylist = false
    @State private var phoneDownloadTarget: TrackRow?
    @State private var phoneDownloadIsRemoval = false
    @State private var showPhoneDownloadConfirmation = false
#if os(iOS)
    /// Track key whose watch transfer we toasted the *start* of, so we can toast its completion
    /// when it lands in the watch manifest.
    @State private var pendingWatchToastTrackID: String?
    @State private var submittingWatchDownload = false
    @State private var watchDownloadDisplayID: String?
    @State private var watchDownloadSourceID: Int64?
    @State private var watchConfirmation: WatchTransferConfirmation?
    @State private var watchConfirmationTarget: TrackRow?
    @State private var showWatchConfirmation = false
#endif

    var body: some View {
        ZStack {
            npBackground.ignoresSafeArea()
            nowPlayingScroll {
            VStack(spacing: 0) {
                // The grabber belongs to the iPhone's swipe-down screen; on Mac
                // Now Playing is the window's inspector column.
                #if os(iOS)
                Capsule().fill(Palette.ink.opacity(0.35))
                    .frame(width: 36, height: 5).padding(.top, 8)
                #endif

                ArtworkView(
                    image: npArtwork,
                    trackRow: player.currentTrack,
                    seed: player.currentTrack?.album?.title ?? "np",
                    cornerRadius: 16
                )
                .frame(maxWidth: 360)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: Palette.ink.opacity(0.55), radius: 30, y: 16)
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
            .foregroundStyle(Palette.ink)
            }
        }
        .presentationDragIndicator(.hidden)
        .task(id: player.currentTrack?.id) {
            guard let row = player.currentTrack else { return }
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
        }
        .artworkImagePicker(isPresented: $showPhotoPicker) { data in
            guard let row = player.currentTrack,
                  await appState.assignCustomArtwork(toTrack: row, data: data) else { return }
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
            ArtworkInvalidation.shared.invalidate()
        }
        .sheet(isPresented: $showEQ) { EQView() }
        .confirmationDialog(phoneDownloadIsRemoval ? "Remove downloaded audio?" : "Download this track?",
                            isPresented: $showPhoneDownloadConfirmation, titleVisibility: .visible) {
            Button(phoneDownloadIsRemoval ? "Remove Download" : "Download",
                   role: phoneDownloadIsRemoval ? .destructive : nil) {
                guard let row = phoneDownloadTarget else { return }
                let removing = phoneDownloadIsRemoval
                Task {
                    if removing {
                        await appState.removeDownloadFromPhone(rows: [row])
                        ToastCenter.shared.info("Removed download")
                    } else {
                        ToastCenter.shared.progress("Downloading…", tag: "dl.phone")
                        let added = await appState.download(rows: [row])
                        ToastCenter.shared.success(added > 0 ? "Download saved" : "Already saved", tag: "dl.phone")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(phoneDownloadIsRemoval ? "Remove the local download, keeping the track in your library." : "Save this track for offline playback.")
        }
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
        .alert("Remove Artwork", isPresented: $showArtworkDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { deleteArtwork() }
        } message: {
            Text("This will remove the custom artwork for this track.")
        }
#if os(iOS)
        .confirmationDialog(watchConfirmation?.title ?? "Apple Watch", isPresented: $showWatchConfirmation,
                            titleVisibility: .visible) {
            Button(watchConfirmation?.confirmTitle ?? "Confirm") {
                guard let row = watchConfirmationTarget, let action = watchConfirmation else { return }
                if action == .download {
                    submittingWatchDownload = true
                    watchDownloadSourceID = row.id
                }
                Task {
                    switch action {
                    case .download:
                        let id = await appState.downloadToWatch(rows: [row])
                        pendingWatchToastTrackID = id
                        watchDownloadDisplayID = id
                        submittingWatchDownload = false
                    case .remove:
                        await appState.removeFromWatch(rows: [row])
                    }
                }
            }
            Button("No", role: .cancel) {}
        } message: {
            Text(watchConfirmation?.message ?? "")
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
#endif
    }

    /// The iPhone screen is sized to the display; the Mac inspector column can
    /// be shorter than the artwork, transport and queue together, so it scrolls.
    @ViewBuilder
    private func nowPlayingScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        ScrollView { content().padding(.vertical, 12) }
        #else
        content()
        #endif
    }

    private func deleteArtwork() {
        guard let row = player.currentTrack else { return }
        Task {
            await appState.clearCustomArtwork(trackId: row.id)
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
            ArtworkInvalidation.shared.invalidate()
        }
    }

    private var npBackground: some View {
        LinearGradient(stops: [
            .init(color: Palette.accent.opacity(0.24), location: 0),
            .init(color: Palette.accent.opacity(0.12), location: 0.34),
            .init(color: Palette.surface, location: 0.78),
            .init(color: Palette.background, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var meta: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.track.title ?? String(localized: "Nothing playing"))
                    .font(Typography.headline).lineLimit(1)
                Text(player.currentTrack.flatMap { $0.artist?.name ?? $0.album?.artist } ?? "")
                    .font(Typography.callout).foregroundStyle(Palette.inkSecondary)
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
                    Capsule().fill(Palette.ink.opacity(0.16))
                    Capsule().fill(Palette.ink.opacity(0.30))
                        .frame(width: w * player.cachedFraction)
                    Capsule().fill(Palette.ink.opacity(0.9))
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
                    .font(Typography.caption).kerning(0.8)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline))
                Spacer()
                Text("-" + TimeFmt.mmss(max(0, player.duration - player.currentTime)))
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TimeFmt.mmss(player.currentTime)) of \(TimeFmt.mmss(player.duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 15
            let next: TimeInterval
            switch direction {
            case .increment:
                next = min(player.duration, player.currentTime + step)
            case .decrement:
                next = max(0, player.currentTime - step)
            @unknown default:
                return
            }
            player.seek(to: next)
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
                Image(systemName: "backward.fill").font(Typography.headline)
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Previous Track")
            .accessibilityIdentifier("np.prev")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(Typography.title)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 66, height: 66).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("np.playpause")
            .accessibilityValue(player.isPlaying ? "playing" : "paused")
            .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(Typography.headline)
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Next Track")
            .accessibilityIdentifier("np.next")
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon).font(Typography.headline)
                    .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Repeat")
            .accessibilityIdentifier("np.repeat")
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle").font(Typography.headline)
                    .foregroundStyle(player.shuffle ? Palette.accent : Palette.inkSecondary)
                    .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.isAmbient)
            .accessibilityLabel("Shuffle")
            .accessibilityIdentifier("np.shuffle")
        }
        .foregroundStyle(Palette.ink)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                if let row = player.currentTrack { Task { await appState.toggleFavorite(row) } }
            } label: {
                Image(systemName: player.currentTrack.map { appState.isFavorite($0) } == true ? "heart.fill" : "heart")
                    .foregroundStyle(player.currentTrack.map { appState.isFavorite($0) } == true ? Palette.danger : Palette.inkSecondary)
                    .font(Typography.body).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.currentTrack == nil)
            .accessibilityLabel("Favorite")
            .accessibilityIdentifier("np.favorite")
            .sensoryFeedback(.success, trigger: appState.favoriteIds)
            .symbolEffect(.bounce, value: player.currentTrack.map { appState.isFavorite($0) } == true)

            Button { showAddToPlaylist = true } label: {
                Image(systemName: "text.badge.plus").font(Typography.body)
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.currentTrack == nil || player.isAmbient)
            .accessibilityLabel("Add to Playlist")
            .accessibilityIdentifier("np.addToPlaylist")

            #if os(iOS)
            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("np.airplay")
            #endif

            phoneDownloadButton(for: player.currentTrack)
            #if os(iOS)
            watchButton(for: player.currentTrack)
            #endif

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
                    .font(Typography.body)
                    .foregroundStyle((player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack) ? Palette.accent : Palette.inkSecondary)
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
                    phoneDownloadTarget = row
                    phoneDownloadIsRemoval = false
                    showPhoneDownloadConfirmation = true
                }
            case .downloaded:
                if let row {
                    phoneDownloadTarget = row
                    phoneDownloadIsRemoval = true
                    showPhoneDownloadConfirmation = true
                }
            case .downloading:
                break
            }
        } label: {
            downloadGlyph(for: row, fallback: state)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("np.download")
        .accessibilityLabel(state == .downloaded ? "Downloaded. Manage download" : "Download track")
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
                Image(systemName: fallback == .downloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(fallback == .downloaded ? Palette.accent : Palette.inkSecondary)
            }
        }
        .frame(width: 45, height: 45)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
    }

    #if os(iOS)
    @ViewBuilder
    private func watchButton(for row: TrackRow?) -> some View {
        let state = displayedWatchState(for: row)
        Button {
            switch state {
            case .notOnWatch, .failed:
                if let row {
                    pendingWatchToastTrackID = PhoneWatchID.track(row.track).rawValue
                    watchConfirmation = .download
                    watchConfirmationTarget = row
                    showWatchConfirmation = true
                }
            case .onWatch:
                if let row {
                    watchConfirmation = .remove
                    watchConfirmationTarget = row
                    showWatchConfirmation = true
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
                    WatchGlyphView(state: displayedWatchState(for: row))
                }
            } else {
                WatchGlyphView(state: fallback)
            }
        }
        .frame(width: 45, height: 45)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
    }

    private func displayedWatchState(for row: TrackRow?) -> WatchGlyphState {
        guard let row else { return .notOnWatch }
        if watchDownloadSourceID == row.id {
            if submittingWatchDownload { return .transferring(progress: nil) }
            if let id = watchDownloadDisplayID { return appState.watchGlyphState(forTrackID: id) }
        }
        return appState.watchGlyphState(for: row)
    }
    #endif

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
