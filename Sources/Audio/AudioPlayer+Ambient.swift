#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Built-in / Ambient

    public func playAmbient(channelId: String) {
        guard let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) else { return }
        cancelCrossfade(resetVolume: true)
        shutdownLoopPlayer()
        shutdownLoaders()
        player.pause()
        player.replaceCurrentItem(with: nil)

        isAmbient = true
        ambientChannelId = channelId
        queueSource = .ambient

        let item = AVPlayerItem(url: url)
        let qp = AVQueuePlayer()
        qp.actionAtItemEnd = .advance
        audioLooper = AVPlayerLooper(player: qp, templateItem: item)
        loopPlayer = qp

        if let row = BuiltInContentProvider.allTrackRows.first(where: {
            $0.asset?.relPath?.contains(channelId) == true
        }) {
            queue = [row]
            index = 0
            duration = 0
            currentTime = 0
        }

        qp.play()
        isPlaying = true
        cacheState = .cached
        cachePercent = 100
        cachedFraction = 1
        updateNowPlaying()
    }

    public func nextAmbientTrack() {
        guard isAmbient, let currentId = ambientChannelId else { return }
        let allIds = BuiltInContentProvider.tracks.map { $0.channelId }
        guard let idx = allIds.firstIndex(of: currentId) else { return }
        let nextIdx = (idx + 1) % allIds.count
        playAmbient(channelId: allIds[nextIdx])
    }

    public func previousAmbientTrack() {
        guard isAmbient, let currentId = ambientChannelId else { return }
        let allIds = BuiltInContentProvider.tracks.map { $0.channelId }
        guard let idx = allIds.firstIndex(of: currentId) else { return }
        let prevIdx = (idx - 1 + allIds.count) % allIds.count
        playAmbient(channelId: allIds[prevIdx])
    }

    func loadBuiltInAsset(_ asset: Asset, row: TrackRow, autoplay: Bool) {
        guard let relPath = asset.relPath else { return }
        let name = (relPath as NSString).deletingPathExtension
        let ext = (relPath as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 120
        item.automaticallyPreservesTimeOffsetFromLive = false

        replaceItem(item)
        if autoplay {
            player.play()
            isPlaying = true
        }
        duration = row.track.durationSec ?? 0
        updateNowPlaying()
    }

    func shutdownLoopPlayer() {
        loopPlayer?.pause()
        audioLooper?.disableLooping()
        audioLooper = nil
        loopPlayer = nil
        isAmbient = false
        ambientChannelId = nil
    }
}
#endif
