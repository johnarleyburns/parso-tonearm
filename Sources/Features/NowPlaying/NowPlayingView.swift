import SwiftUI
import UIKit
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
    /// AirPlay is the one action a SwiftUI `Menu` cannot host directly (the
    /// system route picker is a `UIView`), so its menu item presents this
    /// small picker sheet.
    @State private var showAirPlayPicker = false
    @State private var phoneDownloadTarget: TrackRow?
    @State private var phoneDownloadIsRemoval = false
    @State private var showPhoneDownloadConfirmation = false
    /// Track key whose watch transfer we toasted the *start* of, so we can toast its completion
    /// when it lands in the watch manifest.
    @State private var pendingWatchToastTrackID: String?
    @State private var submittingWatchDownload = false
    @State private var watchDownloadDisplayID: String?
    @State private var watchDownloadSourceID: Int64?
    @State private var watchConfirmation: WatchTransferConfirmation?
    @State private var watchConfirmationTarget: TrackRow?
    @State private var showWatchConfirmation = false

    var body: some View {
        ZStack {
            npBackground.ignoresSafeArea()
            nowPlayingScroll {
            VStack(spacing: 0) {
                // The grabber belongs to the iPhone's swipe-down screen.
                Capsule().fill(Palette.ink.opacity(0.35))
                    .frame(width: 36, height: 5).padding(.top, 8)

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
                    // Real report: this card ("Continuous playback", "No blend plan for this
                    // transition"...) was a confusing leftover from the removed automatic/manual
                    // blend features — removed. See also UpNextView.swift's connector-row removal.
                }
                transport.padding(.top, 16)
                UpNextView()
                    .padding(.top, 20)
            }
            .padding(.horizontal, 24)
            .foregroundStyle(Palette.ink)
            }
        }
        .presentationDragIndicator(.hidden)
        // Real report: Now Playing showed both a "<" back button and the zoom transition's own
        // swipe-down-to-collapse-into-the-mini-player gesture — two ways to do the same thing.
        // The swipe gesture is the only one asked for; it's unaffected by hiding the back button
        // (RootTabChrome's pop-sync already reacts to the navigation path's depth changing, not
        // specifically to a tap on "<", so a swipe-triggered pop still syncs `showNowPlaying`
        // exactly as before).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu
            }
        }
        .onAppear { LocalPlaybackDiagnostics.shared.record(.nowPlayingAppear, loadID: 0) }
        .onDisappear { LocalPlaybackDiagnostics.shared.record(.nowPlayingDisappear, loadID: 0) }
        .task(id: player.currentTrack?.id) {
            guard let row = player.currentTrack else { return }
            LocalPlaybackDiagnostics.shared.record(.artworkRequest, loadID: 0)
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
        }
        .artworkImagePicker(isPresented: $showPhotoPicker) { data in
            guard let row = player.currentTrack,
                  await appState.assignCustomArtwork(toTrack: row, data: data) else { return }
            npArtwork = await ArtworkService.shared.artwork(forTrackRow: row)
            ArtworkInvalidation.shared.invalidate()
        }
        .sheet(isPresented: $showEQ) { EQView() }
        .sheet(isPresented: $showAirPlayPicker) {
            airPlayPickerSheet
        }
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
    }

    /// The queue renders inline so the header and transport stay reachable however long the queue is.
    @ViewBuilder
    private func nowPlayingScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content() }
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
            if !player.isAmbient {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(Typography.headline)
                        .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Previous Track")
                .accessibilityIdentifier("np.prev")
            }
            Button { player.togglePlayPause() } label: {
                // Matches the mini player's buffering affordance (PlayerAccessory.swift): without
                // it, this button looked falsely confident during exactly the window a tap might
                // not do anything yet (still-unconfirmed first play, `shouldIgnoreToggle`).
                if player.isStalled {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Palette.ink)
                        .frame(width: 66, height: 66).background(.ultraThinMaterial, in: Circle())
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(Typography.title)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 66, height: 66).background(.ultraThinMaterial, in: Circle())
                }
            }
            .accessibilityLabel(player.isStalled ? "Buffering" : (player.isPlaying ? "Pause" : "Play"))
            .accessibilityIdentifier("np.playpause")
            .accessibilityValue(player.isStalled ? "Buffering" : (player.isPlaying ? "playing" : "paused"))
            .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
            if !player.isAmbient {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(Typography.headline)
                        .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Next Track")
                .accessibilityIdentifier("np.next")
            }
        }
        .foregroundStyle(Palette.ink)
    }

    // MARK: - Right-side glass actions menu

    private var isFavorite: Bool {
        player.currentTrack.map { appState.isFavorite($0) } == true
    }

    private var repeatTitle: String {
        switch player.repeatMode {
        case .off: return String(localized: "Repeat Off")
        case .all: return String(localized: "Repeat All")
        case .one: return String(localized: "Repeat One")
        }
    }

    private var phoneDownloadTitle: String {
        guard let row = player.currentTrack else { return String(localized: "Download") }
        switch appState.phoneDownloadState(for: row) {
        case .notDownloaded: return String(localized: "Download")
        case .downloaded: return String(localized: "Remove Download")
        case .downloading: return String(localized: "Downloading…")
        }
    }

    private var phoneDownloadIcon: String {
        guard let row = player.currentTrack else { return "arrow.down.circle" }
        switch appState.phoneDownloadState(for: row) {
        case .downloaded: return "arrow.down.circle.fill"
        case .notDownloaded, .downloading: return "arrow.down.circle"
        }
    }

    private var watchTitle: String {
        guard let row = player.currentTrack else { return String(localized: "Add to Apple Watch") }
        switch displayedWatchState(for: row) {
        case .onWatch: return String(localized: "Remove from Apple Watch")
        case .transferring: return String(localized: "Sending to Apple Watch…")
        case .failed: return String(localized: "Retry Apple Watch Transfer")
        case .notOnWatch: return String(localized: "Add to Apple Watch")
        }
    }

    private var sleepTitle: String {
        player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack
            ? String(localized: "Sleep Timer On")
            : String(localized: "Sleep Timer")
    }

    private var sleepIcon: String {
        player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack ? "moon.zzz.fill" : "moon.zzz"
    }

    /// One discoverable place for every secondary action (icons + text), in the
    /// top-right toolbar. Playback's primary transport stays on the sheet.
    private var actionsMenu: some View {
        Menu {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.down") }
                .accessibilityIdentifier("np.back")
            Divider()

            if !player.isAmbient {
                Button { player.cycleRepeatMode() } label: {
                    Label(repeatTitle, systemImage: repeatIcon)
                }
                .accessibilityIdentifier("np.repeat")

                Button { player.shuffle.toggle() } label: {
                    Label(player.shuffle ? String(localized: "Shuffle On") : String(localized: "Shuffle"),
                          systemImage: "shuffle")
                }
                .accessibilityIdentifier("np.shuffle")

                Button { toggleFavorite() } label: {
                    Label(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Favorite"),
                          systemImage: isFavorite ? "heart.fill" : "heart")
                }
                .disabled(player.currentTrack == nil)
                .accessibilityIdentifier("np.favorite")

                Button { showAddToPlaylist = true } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
                .disabled(player.currentTrack == nil)
                .accessibilityIdentifier("np.addToPlaylist")
            }

            Button { showAirPlayPicker = true } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }
            .accessibilityIdentifier("np.airplay")

            if !player.isAmbient {
                Button { requestPhoneDownload() } label: {
                    Label(phoneDownloadTitle, systemImage: phoneDownloadIcon)
                }
                .disabled(player.currentTrack == nil)
                .accessibilityIdentifier("np.download")

                Button { requestWatchTransfer() } label: {
                    Label(watchTitle, systemImage: "applewatch")
                }
                .disabled(player.currentTrack == nil)
                .accessibilityIdentifier("np.watchDownload")
            }

            Menu {
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
                Label(sleepTitle, systemImage: sleepIcon)
            }
            .accessibilityIdentifier("np.sleep")

            if !player.isAmbient, player.currentTrack != nil {
                Divider()
                Button { showPhotoPicker = true } label: {
                    Label("Change Artwork", systemImage: "photo.badge.plus")
                }
                if npArtwork != nil {
                    Button(role: .destructive) { showArtworkDeleteAlert = true } label: {
                        Label("Remove Artwork", systemImage: "trash")
                    }
                }
                Button { showEQ = true } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
            }
            if !player.isAmbient, let row = player.currentTrack, let url = shareURL(for: row) {
                ShareLink(item: url) { Label("Share Artwork", systemImage: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .accessibilityLabel("Now Playing Actions")
        .accessibilityIdentifier("np.actions")
        .sensoryFeedback(.success, trigger: appState.favoriteIds)
    }

    private var airPlayPickerSheet: some View {
        VStack(spacing: 16) {
            Text("AirPlay")
                .font(Typography.headline)
            AirPlayButton()
                .frame(width: 52, height: 52)
            Text("Tap the AirPlay icon to choose a device.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { showAirPlayPicker = false }
                .font(Typography.callout)
                .foregroundStyle(Palette.accent)
        }
        .padding(24)
        .presentationDetents([.height(220)])
        .accessibilityIdentifier("np.airplayPicker")
    }

    private func toggleFavorite() {
        guard let row = player.currentTrack else { return }
        Task { await appState.toggleFavorite(row) }
    }

    private func requestPhoneDownload() {
        guard let row = player.currentTrack else { return }
        switch appState.phoneDownloadState(for: row) {
        case .notDownloaded:
            phoneDownloadTarget = row
            phoneDownloadIsRemoval = false
            showPhoneDownloadConfirmation = true
        case .downloaded:
            phoneDownloadTarget = row
            phoneDownloadIsRemoval = true
            showPhoneDownloadConfirmation = true
        case .downloading:
            break
        }
    }

    private func requestWatchTransfer() {
        guard let row = player.currentTrack else { return }
        switch displayedWatchState(for: row) {
        case .notOnWatch, .failed:
            pendingWatchToastTrackID = PhoneWatchID.track(row.track).rawValue
            watchConfirmation = .download
            watchConfirmationTarget = row
            showWatchConfirmation = true
        case .onWatch:
            watchConfirmation = .remove
            watchConfirmationTarget = row
            showWatchConfirmation = true
        case .transferring:
            break
        }
    }

    private func displayedWatchState(for row: TrackRow?) -> WatchGlyphState {
        guard let row else { return .notOnWatch }
        if watchDownloadSourceID == row.id {
            if submittingWatchDownload { return .transferring(progress: nil) }
            if let id = watchDownloadDisplayID { return appState.watchGlyphState(forTrackID: id) }
        }
        return appState.watchGlyphState(for: row)
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
