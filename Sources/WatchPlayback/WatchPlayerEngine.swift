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

    public init(trackKeys: [String] = [], currentIndex: Int = 0,
                elapsed: Double = 0, isPlaying: Bool = false) {
        self.trackKeys = trackKeys
        self.currentIndex = currentIndex
        self.elapsed = elapsed
        self.isPlaying = isPlaying
    }
}

public enum WatchRepeatMode: Equatable {
    case off
    case all
    case one
}

// MARK: - Player Engine

public struct WatchPlayerEngine: Equatable {
    public private(set) var queue: [String]
    public private(set) var currentIndex: Int
    public private(set) var isPlaying: Bool
    public private(set) var elapsed: Double
    public private(set) var repeatMode: WatchRepeatMode
    public private(set) var isShuffled: Bool

    private var shuffleOrder: [Int]
    private var lastDirectives: [WatchEngineDirective]

    public init(queue: [String] = [], startIndex: Int = 0) {
        self.queue = queue
        self.currentIndex = startIndex < queue.count ? startIndex : 0
        self.isPlaying = false
        self.elapsed = 0
        self.repeatMode = .off
        self.isShuffled = false
        self.shuffleOrder = []
        self.lastDirectives = []
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
            buildShuffleOrder()
        }
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
        if isShuffled { buildShuffleOrder() }
    }

    public var snapshot: WatchQueueSnapshot {
        WatchQueueSnapshot(trackKeys: queue, currentIndex: currentIndex,
                            elapsed: elapsed, isPlaying: isPlaying)
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
        var indices = Array(0..<queue.count)
        if indices.count > 1 {
            indices.remove(at: currentIndex)
            indices.shuffle()
            indices.insert(currentIndex, at: 0)
        }
        shuffleOrder = indices
        // Reorder queue according to shuffle
        queue = shuffleOrder.map { queue[$0] }
        currentIndex = 0
    }
}
