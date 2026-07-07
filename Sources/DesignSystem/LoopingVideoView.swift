import SwiftUI
import AVFoundation

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

    static func dismantleUIView(_ uiView: LoopingPlayerUIView, coordinator: ()) {
        uiView.teardown()
    }
}

final class LoopingPlayerUIView: UIView {
    override class var layerClass: AnyClass { CALayer.self }

    private let playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var videoAspect: CGFloat?

    var horizontalAnchor: CGFloat = 0.5 {
        didSet { if horizontalAnchor != oldValue { setNeedsLayout() } }
    }

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

    func update(url: URL) {
        guard url != currentURL else { return }
        teardown()
        setup(url: url)
    }

    func setPlaying(_ playing: Bool) {
        guard let qp = queuePlayer else { return }
        if playing {
            if qp.timeControlStatus != .playing { qp.play() }
        } else {
            qp.pause()
        }
    }

    private func setup(url: URL) {
        currentURL = url
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let qp = AVQueuePlayer()
        qp.isMuted = true
        qp.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: qp, templateItem: item)
        playerLayer.player = qp
        queuePlayer = qp
        qp.play()

        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let tf = try? await track.load(.preferredTransform)
            else { return }
            let r = size.applying(tf)
            let w = abs(r.width), h = abs(r.height)
            guard w > 0, h > 0 else { return }
            await MainActor.run {
                self?.videoAspect = w / h
                self?.setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        guard let aspect = videoAspect else {
            playerLayer.frame = b
            return
        }
        let viewAspect = b.width / b.height
        var f = b
        if aspect > viewAspect {
            let w = b.height * aspect
            f = CGRect(x: (b.width - w) * horizontalAnchor, y: 0,
                       width: w, height: b.height)
        } else {
            let h = b.width / aspect
            f = CGRect(x: 0, y: (b.height - h) * 0.5,
                       width: b.width, height: h)
        }
        playerLayer.frame = f
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
