import CoreGraphics

public struct DJGridLayout: Equatable, Sendable {
    public let size: CGSize
    public let gap: CGFloat
    public let cellWidth: CGFloat
    public let rowHeight: CGFloat

    public init(size: CGSize, gap: CGFloat = 6) {
        self.size = size
        self.gap = gap
        cellWidth = max(0, (size.width - gap * 7) / 8)
        rowHeight = max(0, (size.height - gap * 7) / 8)
    }

    public func frame(col: Int, row: Int, span: Int = 1) -> CGRect {
        let safeCol = max(0, min(7, col))
        let safeRow = max(0, min(7, row))
        let safeSpan = max(1, min(8 - safeCol, span))
        return CGRect(x: CGFloat(safeCol) * (cellWidth + gap),
                      y: CGFloat(safeRow) * (rowHeight + gap),
                      width: CGFloat(safeSpan) * cellWidth + CGFloat(safeSpan - 1) * gap,
                      height: rowHeight)
    }
}

public enum DJPadMode: String, Codable, Sendable {
    case hotCue
    case echo
    case loop
}

public enum DJKeyFormatter {
    public static func format(_ raw: String?) -> String {
        guard let raw, raw.range(of: #"^(1[0-2]|[1-9])[AB]$"#, options: .regularExpression) != nil else {
            return "—"
        }
        return raw
    }
}

public struct DJCueTransport: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case cueDown
        case cueUp
        case playTap
        case seek(Double)
        case trackEnded
    }

    public enum Action: Equatable, Sendable {
        case setCue(Double)
        case play
        case pause
        case jumpToCue
        case cuePlayPress
        case cuePlayRelease
        case seek(Double)
        case none
    }

    public private(set) var sampling = false
    public private(set) var playContinuesAfterCue = false

    public init() {}

    public mutating func reduce(_ input: Input, isPlaying: Bool, position: Double,
                                cuePoint: Double?) -> Action {
        switch input {
        case .cueDown:
            if isPlaying {
                sampling = false
                return .jumpToCue
            }
            let cue = cuePoint ?? position
            if abs(position - cue) > 0.01 { sampling = true; return .setCue(position) }
            sampling = true
            return .cuePlayPress
        case .cueUp:
            guard sampling else { return .none }
            sampling = false
            if playContinuesAfterCue { playContinuesAfterCue = false; return .none }
            return .cuePlayRelease
        case .playTap:
            if sampling { playContinuesAfterCue = true }
            return isPlaying ? .pause : .play
        case .seek(let value):
            return isPlaying ? .none : .seek(max(0, value))
        case .trackEnded:
            sampling = false
            playContinuesAfterCue = false
            return .pause
        }
    }
}

