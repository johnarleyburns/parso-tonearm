import SwiftUI
import AVFoundation
import UIKit

struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var horizontalAnchor: CGFloat = 0.5
    var isPlaying: Bool = true

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(url: url, horizontalAnchor: horizontalAnchor)
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {
        uiView.horizontalAnchor = horizontalAnchor
        uiView.update(url: url)
        uiView.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ uiView: LoopingPlayerUIView, coordinator: ()) { uiView.teardown() }
}

final class LoopingPlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var videoAspect: CGFloat?
    var horizontalAnchor: CGFloat = 0.5 { didSet { if horizontalAnchor != oldValue { setNeedsLayout() } } }

    init(url: URL, horizontalAnchor: CGFloat) {
        self.horizontalAnchor = horizontalAnchor
        super.init(frame: .zero)
        clipsToBounds = true
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspectFill
        setup(url: url)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspectFill
    }

    func update(url: URL) { guard url != currentURL else { return }; teardown(); setup(url: url) }
    func setPlaying(_ playing: Bool) { playing ? queuePlayer?.play() : queuePlayer?.pause() }

    private func setup(url: URL) {
        currentURL = url
        let asset = AVURLAsset(url: url)
        let qp = AVQueuePlayer(items: [AVPlayerItem(asset: asset)])
        qp.isMuted = true
        qp.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: qp, templateItem: AVPlayerItem(asset: asset))
        playerLayer.player = qp
        queuePlayer = qp
        qp.play()
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let rect = size.applying(transform)
            guard abs(rect.width) > 0, abs(rect.height) > 0 else { return }
            await MainActor.run { self?.videoAspect = abs(rect.width / rect.height); self?.setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let aspect = videoAspect else { playerLayer.frame = bounds; return }
        let viewAspect = bounds.width / bounds.height
        if aspect > viewAspect {
            let width = bounds.height * aspect
            playerLayer.frame = CGRect(x: (bounds.width - width) * horizontalAnchor, y: 0,
                                       width: width, height: bounds.height)
        } else {
            let height = bounds.width / aspect
            playerLayer.frame = CGRect(x: 0, y: (bounds.height - height) * 0.5,
                                       width: bounds.width, height: height)
        }
    }

    func teardown() {
        queuePlayer?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        queuePlayer = nil
        currentURL = nil
    }
}
