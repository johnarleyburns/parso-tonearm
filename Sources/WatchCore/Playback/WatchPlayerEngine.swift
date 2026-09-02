import Foundation

public enum WatchEngineDirective: Equatable {
    case loadItem(URL)
    case play
    case pause
    case seek(to: Double)
    case stop
}

public enum WatchEngineCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    case jump(to: Int)
    case seek(to: Double)
    case itemEnded
    case itemFailed
    case routeLost
}

public struct WatchQueueSnapshot: Codable, Equatable {
    public var trackKeys: [String]
    public var currentIndex: Int
    public var elapsed: Double
    public var isPlaying: Bool
    public var isShuffled: Bool
    /// The seed the deterministic shuffle was built from. Persisted so a relaunch that rebuilds an
    /// order from the same input queue lands on the same sequence (§7.3).
    public var shuffleSeed: UInt64
    public var repeatMode: WatchRepeatMode

    public init(trackKeys: [String] = [], currentIndex: Int = 0,
                elapsed: Double = 0, isPlaying: Bool = false,
                isShuffled: Bool = false, shuffleSeed: UInt64 = 0,
                repeatMode: WatchRepeatMode = .off) {
        self.trackKeys = trackKeys
        self.currentIndex = currentIndex
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.isShuffled = isShuffled
        self.shuffleSeed = shuffleSeed
        self.repeatMode = repeatMode
    }

    /// Custom decode so a position persisted by a pre-Phase-9 build (no shuffle/repeat keys) still
    /// restores instead of throwing and being discarded as corrupt.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackKeys = try c.decode([String].self, forKey: .trackKeys)
        currentIndex = try c.decode(Int.self, forKey: .currentIndex)
        elapsed = try c.decode(Double.self, forKey: .elapsed)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        isShuffled = try c.decodeIfPresent(Bool.self, forKey: .isShuffled) ?? false
        shuffleSeed = try c.decodeIfPresent(UInt64.self, forKey: .shuffleSeed) ?? 0
        repeatMode = try c.decodeIfPresent(WatchRepeatMode.self, forKey: .repeatMode) ?? .off
    }
}

public enum WatchRepeatMode: String, Codable, Equatable {
    case off
    case all
    case one
}

/// A small deterministic generator (SplitMix64) so a session's shuffle order is a pure function of
/// its seed and input queue — reproducible across a relaunch without persisting the whole permutation.
struct WatchSeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Player Engine

public struct WatchPlayerEngine: Equatable {
    public private(set) var queue: [String]
    public private(set) var currentIndex: Int
    public private(set) var isPlaying: Bool
    public private(set) var elapsed: Double
    public private(set) var repeatMode: WatchRepeatMode
    public private(set) var isShuffled: Bool
    /// Non-zero once shuffle has been enabled in this session; see `WatchSeededRNG`.
    public private(set) var shuffleSeed: UInt64

    private var shuffleOrder: [Int]
    private var lastDirectives: [WatchEngineDirective]

    public init(queue: [String] = [], startIndex: Int = 0) {
        self.queue = queue
        self.currentIndex = startIndex < queue.count ? startIndex : 0
        self.isPlaying = false
        self.elapsed = 0
        self.repeatMode = .off
        self.isShuffled = false
        self.shuffleSeed = 0
        self.shuffleOrder = []
        self.lastDirectives = []
    }

    /// Rebuild a paused engine from a persisted snapshot, dropping any track whose file is no longer
    /// available (§7.3 "queue restoration with missing files"). The current index is remapped to the
    /// still-available track nearest the saved position; elapsed is kept only if that track survived.
    public static func restored(from snapshot: WatchQueueSnapshot,
                                availableKeys: Set<String>) -> WatchPlayerEngine {
        var valid: [String] = []
        var mappedCurrent: Int?
        var lastBefore = 0
        var firstAfter: Int?
        for (i, key) in snapshot.trackKeys.enumerated() where availableKeys.contains(key) {
            valid.append(key)
            let newIdx = valid.count - 1
            if i == snapshot.currentIndex {
                mappedCurrent = newIdx
            } else if i < snapshot.currentIndex {
                lastBefore = newIdx
            } else if firstAfter == nil {
                firstAfter = newIdx
            }
        }
        let currentSurvived = mappedCurrent != nil
        let start = mappedCurrent ?? firstAfter ?? lastBefore
        var engine = WatchPlayerEngine(queue: valid, startIndex: start)
        engine.repeatMode = snapshot.repeatMode
        engine.isShuffled = snapshot.isShuffled
        engine.shuffleSeed = snapshot.shuffleSeed
        engine.elapsed = currentSurvived && !valid.isEmpty ? max(0, snapshot.elapsed) : 0
        engine.isPlaying = false
        return engine
    }

    public var currentTrack: String? {
        guard !queue.isEmpty, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    public var canPlayNext: Bool {
        guard !queue.isEmpty else { return false }
        if repeatMode == .all || repeatMode == .one { return true }
        return currentIndex < queue.count - 1
    }

    public var canPlayPrevious: Bool {
        guard !queue.isEmpty else { return false }
        if repeatMode == .all { return true }
        return currentIndex > 0
    }

    public var directives: [WatchEngineDirective] { lastDirectives }

    // MARK: - Commands

    @discardableResult
    public mutating func command(_ cmd: WatchEngineCommand,
                                  urlForTrack: ((String) -> URL?)? = nil) -> [WatchEngineDirective] {
        lastDirectives = []
        let urlProvider: (String) -> URL? = urlForTrack ?? { _ in nil }
        switch cmd {
        case .play: handlePlay(urlProvider)
        case .pause: handlePause()
        case .togglePlayPause: handleToggle(urlProvider)
        case .next: handleNext(urlProvider)
        case .previous: handlePrevious(urlProvider)
        case .jump(let idx): handleJump(to: idx, urlForTrack: urlProvider)
        case .seek(let pos): handleSeek(to: pos)
        case .itemEnded: handleItemEnded(urlProvider)
        case .itemFailed: handleItemFailed(urlProvider)
        case .routeLost: handleRouteLost()
        }
        return lastDirectives
    }

    public mutating func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            if shuffleSeed == 0 { shuffleSeed = UInt64.random(in: 1...UInt64.max) }
            buildShuffleOrder()
        }
    }

    /// Explicit shuffle set with an injectable seed — used by tests and by restoration to reproduce a
    /// prior session's order.
    public mutating func setShuffle(_ enabled: Bool, seed: UInt64? = nil) {
        isShuffled = enabled
        guard enabled else { return }
        if let seed { shuffleSeed = seed }
        else if shuffleSeed == 0 { shuffleSeed = UInt64.random(in: 1...UInt64.max) }
        buildShuffleOrder()
    }

    public mutating func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    public mutating func setQueue(_ newQueue: [String], startIndex: Int = 0) {
        queue = newQueue
        currentIndex = min(startIndex, max(0, newQueue.count - 1))
        elapsed = 0
        isPlaying = false
        if isShuffled { buildShuffleOrder() }
    }

    /// Reconciles the pure request state with the platform adapter. Commands optimistically request
    /// playback so they can emit directives, while the AVPlayer adapter may later report that the
    /// route or item was not actually usable.
    public mutating func setConfirmedPlaying(_ playing: Bool) {
        isPlaying = playing
    }

    public var snapshot: WatchQueueSnapshot {
        WatchQueueSnapshot(trackKeys: queue, currentIndex: currentIndex,
                            elapsed: elapsed, isPlaying: isPlaying,
                            isShuffled: isShuffled, shuffleSeed: shuffleSeed,
                            repeatMode: repeatMode)
    }

    // MARK: - Private

    private mutating func handlePlay(_ urlForTrack: (String) -> URL?) {
        guard let track = currentTrack, let url = urlForTrack(track) else {
            lastDirectives = []
            return
        }
        isPlaying = true
        lastDirectives = [.loadItem(url), .play]
    }

    private mutating func handlePause() {
        isPlaying = false
        lastDirectives = [.pause]
    }

    private mutating func handleToggle(_ urlForTrack: (String) -> URL?) {
        if isPlaying {
            handlePause()
        } else {
            handlePlay(urlForTrack)
        }
    }

    private mutating func handleNext(_ urlForTrack: (String) -> URL?) {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            elapsed = 0
            if let url = currentTrack.flatMap({ urlForTrack($0) }) {
                lastDirectives = [.loadItem(url), .play]
                isPlaying = true
            }
            return
        }
        advance(by: 1)
        playCurrent(urlForTrack)
    }

    private mutating func handlePrevious(_ urlForTrack: (String) -> URL?) {
        guard !queue.isEmpty else { return }
        if elapsed <= 3.0 {
            elapsed = 0
            playCurrent(urlForTrack)
            return
        }
        advance(by: -1)
        playCurrent(urlForTrack)
    }

    private mutating func handleItemEnded(_ urlForTrack: (String) -> URL?) {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            elapsed = 0
            playCurrent(urlForTrack)
            return
        }
        let endOfQueue = currentIndex >= queue.count - 1
        if endOfQueue && repeatMode != .all {
            isPlaying = false
            lastDirectives = [.stop]
            return
        }
        advance(by: 1)
        playCurrent(urlForTrack)
    }

    private mutating func handleItemFailed(_ urlForTrack: (String) -> URL?) {
        guard !queue.isEmpty else { return }
        // Skip to next, but if we're at the end with repeat off, stop.
        if currentIndex >= queue.count - 1 && repeatMode != .all {
            isPlaying = false
            lastDirectives = [.stop]
            return
        }
        advance(by: 1)
        playCurrent(urlForTrack)
    }

    private mutating func handleJump(to index: Int, urlForTrack: (String) -> URL?) {
        guard index >= 0, index < queue.count else { return }
        currentIndex = index
        elapsed = 0
        playCurrent(urlForTrack)
    }

    private mutating func handleSeek(to position: Double) {
        elapsed = max(0, position)
        lastDirectives = [.seek(to: elapsed)]
    }

    private mutating func handleRouteLost() {
        isPlaying = false
        lastDirectives = [.pause]
    }

    private mutating func advance(by delta: Int) {
        guard !queue.isEmpty else { return }
        let next = currentIndex + delta
        if next < 0 {
            if repeatMode == .all { currentIndex = queue.count - 1 }
            else { currentIndex = 0 }
        } else if next >= queue.count {
            if repeatMode == .all { currentIndex = 0 }
            else { currentIndex = queue.count - 1 }
        } else {
            currentIndex = next
        }
        elapsed = 0
    }

    private mutating func playCurrent(_ urlForTrack: (String) -> URL?) {
        guard let track = currentTrack, let url = urlForTrack(track) else {
            isPlaying = false
            lastDirectives = []
            return
        }
        isPlaying = true
        lastDirectives = [.loadItem(url), .play]
    }

    private mutating func buildShuffleOrder() {
        guard !queue.isEmpty else { return }
        var rng = WatchSeededRNG(seed: shuffleSeed)
        var indices = Array(0..<queue.count)
        if indices.count > 1 {
            indices.remove(at: currentIndex)
            indices.shuffle(using: &rng)
            indices.insert(currentIndex, at: 0)
        }
        shuffleOrder = indices
        // Reorder queue according to shuffle
        queue = shuffleOrder.map { queue[$0] }
        currentIndex = 0
    }
}
