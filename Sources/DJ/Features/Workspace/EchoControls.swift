import SwiftUI

/// The §42.7c compact **ECHO** button: a single always-visible button with a
/// long-press **release-to-commit flyout** for beat length, depth and channel
/// (the same idiom as LOOP, §42.7b idiom 3). Echo Out is a two-control
/// transition — echo on, fader down — so ECHO sits in the always-visible band
/// and both controls are reachable without a drawer (§42.7c, FR-TRANS-4).
///
/// The whole interaction is one drag on the button: touch-down opens the
/// flyout after a short hold (a quick tap is the tap — it toggles the echo),
/// and the release point is resolved against the model's pure
/// `WorkspaceModel.EchoFlyout.releasedAction(at:)` — the engine is touched
/// only on a release inside a commit target. Nothing changes on the way out.
///
/// `deck` is the channel the echo starts on (the solo surface's focused deck,
/// deck A on the twin); the flyout's channel chips switch it.
struct EchoReleaseToCommitButton: View {
    @ObservedObject var model: WorkspaceModel
    /// The channel the button's echo starts on; the flyout can switch it.
    let deck: PerformanceEngine.Deck
    /// Whether the flyout carries the A/B channel chips (the twin surface's
    /// button is shared between both channels; the solo's targets its focus).
    var showsChannelSelector = true

    /// A press held past this opens the flyout; a shorter press is the tap.
    private let openDelay: TimeInterval = 0.30
    /// A press that wanders past this before the delay is a slide, not a hold.
    private let pressTolerance: CGFloat = 20

    @State private var activeDeck: PerformanceEngine.Deck
    @State private var pressStart: Date?
    @State private var dragStart: CGPoint?
    @State private var flyoutOpen = false

    init(model: WorkspaceModel, deck: PerformanceEngine.Deck,
         showsChannelSelector: Bool = true) {
        self.model = model
        self.deck = deck
        self.showsChannelSelector = showsChannelSelector
        _activeDeck = State(initialValue: deck)
    }

    var body: some View {
        GeometryReader { proxy in
            let flyoutFrame = self.flyoutFrame(in: proxy.size)
            ZStack(alignment: .bottomLeading) {
                if flyoutOpen {
                    EchoFlyoutContent(model: model, deck: activeDeck,
                                     showsChannelSelector: showsChannelSelector)
                        .frame(width: flyoutFrame.width, height: flyoutFrame.height)
                        .position(x: flyoutFrame.midX, y: flyoutFrame.midY)
                        .allowsHitTesting(false)
                }
                echoButton
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(flyoutFrame: flyoutFrame))
        }
        .frame(minHeight: 44)
        // A deck change (the solo surface's focus swap) re-arms the button's
        // channel; the flyout's channel chips override it on the twin.
        .onChange(of: deck) { _, newDeck in
            activeDeck = newDeck
        }
    }

    /// The flyout is anchored above the button and horizontally centred over
    /// it, so it never reaches the crossfader below or the decks beside it.
    private func flyoutFrame(in size: CGSize) -> CGRect {
        let width = WorkspaceModel.EchoFlyout.width
        let height = WorkspaceModel.EchoFlyout.height
        return CGRect(x: max(0, (size.width - width) / 2),
                      y: -height, width: width, height: height)
    }

    private var echoButton: some View {
        let on = model.echoEnabled(activeDeck)
        let channel = activeDeck == .a ? "A" : "B"
        return HStack(spacing: 5) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
            Text(showsChannelSelector
                 ? (on ? "ECHO \(channel) · ON" : "ECHO \(channel)")
                 : (on ? "ECHO · ON" : "ECHO"))
                .font(.system(size: 12, weight: .bold))
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .background(
            on ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(on ? Color.accentColor : .primary)
        .accessibilityIdentifier("dj.fx.echo")
        .coachGlow(identifier: "dj.fx.echo")
    }

    private func dragGesture(flyoutFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.location
                    pressStart = Date()
                }
                guard !flyoutOpen, let start = dragStart else { return }
                let held = Date().timeIntervalSince(pressStart ?? Date())
                let wandered = hypot(value.location.x - start.x,
                                     value.location.y - start.y)
                if held > openDelay && wandered < pressTolerance {
                    flyoutOpen = true
                    Haptics.confirm()
                }
            }
            .onEnded { value in
                let held = Date().timeIntervalSince(pressStart ?? Date())
                defer { flyoutOpen = false; dragStart = nil; pressStart = nil }
                if flyoutOpen {
                    let point = CGPoint(x: value.location.x - flyoutFrame.minX,
                                        y: value.location.y - flyoutFrame.minY)
                    if let action = WorkspaceModel.EchoFlyout.releasedAction(at: point) {
                        commit(action)
                    }
                } else if held < openDelay {
                    model.setEchoEnabled(activeDeck, enabled: !model.echoEnabled(activeDeck))
                    Haptics.confirm()
                }
            }
    }

    private func commit(_ action: WorkspaceModel.EchoFlyout.EchoAction) {
        switch action {
        case .channel(let index):
            activeDeck = index == 0 ? .a : .b
        case .beats(let beats):
            model.setEchoBeats(activeDeck, beats: beats)
        case .depth(let depth):
            model.setEchoDepth(activeDeck, depth: depth)
        }
        Haptics.confirm()
    }
}

/// The §42.7c flyout's rendered chips and depth track, each positioned at
/// exactly the model's pure frame so the drag's release resolution is honest
/// to what the user sees.
private struct EchoFlyoutContent: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    var showsChannelSelector = true

    var body: some View {
        VStack(spacing: 0) {
            Text("HOLD ECHO · channel · beats · depth")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: WorkspaceModel.EchoFlyout.headerHeight)
                .padding(.horizontal, 8)

            GeometryReader { proxy in
                ZStack {
                    if showsChannelSelector {
                        ForEach(0..<2, id: \.self) { index in
                            let frame = WorkspaceModel.EchoFlyout.channelChipFrame(index: index)
                            let isActive = (index == 0 ? PerformanceEngine.Deck.a : .b) == deck
                            Text(index == 0 ? "A" : "B")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: WorkspaceModel.EchoFlyout.channelChipWidth,
                                       height: WorkspaceModel.EchoFlyout.channelChipHeight)
                                .background(
                                    isActive ? Color.accentColor.opacity(0.28)
                                             : Color.white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                                .position(CGPoint(x: frame.midX,
                                                  y: frame.midY - WorkspaceModel.EchoFlyout.headerHeight))
                        }
                    }
                    ForEach(Array(WorkspaceModel.EchoFlyout.beats.enumerated()), id: \.offset) { index, beats in
                        let frame = WorkspaceModel.EchoFlyout.chipFrame(index: index)
                        let isActive = model.echoBeats(deck) == beats
                        Text(echoLabel(beats))
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: WorkspaceModel.EchoFlyout.chipWidth,
                                   height: WorkspaceModel.EchoFlyout.chipHeight)
                            .background(
                                isActive ? Color.accentColor.opacity(0.28)
                                         : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                            .position(CGPoint(x: frame.midX,
                                              y: frame.midY - WorkspaceModel.EchoFlyout.headerHeight))
                    }
                    let track = WorkspaceModel.EchoFlyout.depthTrackFrame()
                    let depth = CGFloat(model.echoDepth(deck))
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: track.width, height: 4)
                        .position(CGPoint(x: track.midX,
                                          y: track.midY - WorkspaceModel.EchoFlyout.headerHeight))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, track.width * depth), height: 4)
                        .position(x: track.minX + track.width * depth / 2,
                                  y: track.midY - WorkspaceModel.EchoFlyout.headerHeight)
                }
                .frame(width: WorkspaceModel.EchoFlyout.width,
                       height: WorkspaceModel.EchoFlyout.height
                           - WorkspaceModel.EchoFlyout.headerHeight)
            }
        }
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.07, green: 0.085, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    private func echoLabel(_ beats: Double) -> String {
        beats < 1 ? String(format: "1/%d", Int(1 / beats)) : "\(Int(beats))"
    }
}
