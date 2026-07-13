import SwiftUI
import UIKit
import PhotosUI

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var npArtwork: UIImage?
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showEQ = false

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
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                .padding(.top, 22)
                .overlay {
                    if player.isAmbient, let channelId = player.ambientChannelId,
                       let videoURL = BuiltInContentProvider.bundledVideoURL(forChannelId: channelId) {
                        LoopingVideoView(url: videoURL, isPlaying: player.isPlaying)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .allowsHitTesting(false)
                    } else if npArtwork == nil, !player.isAmbient, player.currentTrack != nil {
                        noImageOverlay
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture {
                    guard npArtwork == nil, !player.isAmbient, player.currentTrack != nil else { return }
                    showPhotoPicker = true
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
    }

    private var noImageOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 28, weight: .light))
            Text("No Image")
                .font(.system(size: 13, weight: .medium))
            Text("Add Artwork")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white.opacity(0.55))
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
                Text(player.currentTrack?.album?.artist ?? "")
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
        HStack(spacing: 14) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 20))
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                    .frame(width: 66, height: 66).background(.ultraThinMaterial, in: Circle())
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 20))
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if let row = player.currentTrack {
                Button {
                    Task { await appState.toggleFavorite(row) }
                } label: {
                    Image(systemName: appState.isFavorite(row) ? "heart.fill" : "heart")
                        .foregroundStyle(appState.isFavorite(row) ? Color.red : .white.opacity(0.6))
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(player.repeatMode != .off ? Palette.brass : .white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16))
                    .foregroundStyle(player.shuffle ? Palette.brass : .white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(player.isAmbient)

            AirPlayButton()
                .frame(width: 36, height: 36)

            Button { showEQ = true } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            if let row = player.currentTrack,
               let shareURL = shareURL(for: row) {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
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
                Image(systemName: player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 16))
                    .foregroundStyle((player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack) ? Palette.brass : .white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
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
