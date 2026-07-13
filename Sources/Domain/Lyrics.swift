import Foundation

struct SyncedLyrics: Equatable {
    struct Line: Equatable, Identifiable {
        var id: Int
        var time: TimeInterval
        var text: String
    }

    var metadata: [String: String]
    var offset: TimeInterval
    var lines: [Line]
    var untimedLines: [String]

    func currentLine(at time: TimeInterval) -> Line? {
        guard !lines.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = lines.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lines[midpoint].time <= time {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return nil }
        return lines[lowerBound - 1]
    }
}

enum LRCParser {
    static func parse(_ raw: String) -> SyncedLyrics {
        struct Entry {
            var time: TimeInterval
            var order: Int
            var text: String
        }

        var metadata: [String: String] = [:]
        var offset: TimeInterval = 0
        var entries: [Entry] = []
        var untimedLines: [String] = []
        var order = 0

        let rawLines = raw.components(separatedBy: .newlines)
        for rawLine in rawLines {
            let line = clean(rawLine)
            guard !line.isEmpty else { continue }

            if let tag = metadataTag(line) {
                metadata[tag.key] = tag.value
                if tag.key == "offset", let milliseconds = Double(tag.value.replacingOccurrences(of: " ", with: "")) {
                    offset = milliseconds / 1_000
                }
                continue
            }

            if let parsed = timestampedLine(line) {
                let lyricText = trimLyricText(parsed.text)
                for time in parsed.times {
                    entries.append(Entry(time: time, order: order, text: lyricText))
                    order += 1
                }
            } else if !line.hasPrefix("[") {
                untimedLines.append(line)
            }
        }

        let sorted = entries.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.order < rhs.order
        }
        let lines = sorted.enumerated().map { index, entry in
            SyncedLyrics.Line(id: index, time: entry.time + offset, text: entry.text)
        }

        return SyncedLyrics(
            metadata: metadata,
            offset: offset,
            lines: lines,
            untimedLines: untimedLines
        )
    }

    private static func clean(_ rawLine: String) -> String {
        rawLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\r"))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func trimLyricText(_ text: Substring) -> String {
        String(text).trimmingCharacters(in: .whitespaces)
    }

    private static func metadataTag(_ line: String) -> (key: String, value: String)? {
        guard line.first == "[", line.last == "]" else { return nil }
        let tokenStart = line.index(after: line.startIndex)
        let tokenEnd = line.index(before: line.endIndex)
        let token = line[tokenStart..<tokenEnd]
        guard let colon = token.firstIndex(of: ":") else { return nil }

        let key = token[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = token.index(after: colon)
        let value = token[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, timestamp(String(token)) == nil else { return nil }
        return (key, value)
    }

    private static func timestampedLine(_ line: String) -> (times: [TimeInterval], text: Substring)? {
        var index = line.startIndex
        var times: [TimeInterval] = []

        while index < line.endIndex, line[index] == "[" {
            guard let close = line[index...].firstIndex(of: "]") else { break }
            let tokenStart = line.index(after: index)
            let token = String(line[tokenStart..<close])
            guard let time = timestamp(token) else { break }
            times.append(time)
            index = line.index(after: close)
        }

        guard !times.isEmpty else { return nil }
        return (times, line[index...])
    }

    private static func timestamp(_ token: String) -> TimeInterval? {
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Int
        let minutes: Int
        let secondsToken: Substring
        if parts.count == 2 {
            hours = 0
            guard let parsedMinutes = Int(parts[0]) else { return nil }
            minutes = parsedMinutes
            secondsToken = parts[1]
        } else {
            guard let parsedHours = Int(parts[0]),
                  let parsedMinutes = Int(parts[1]) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
            secondsToken = parts[2]
        }

        guard hours >= 0, minutes >= 0, parts.count == 2 || minutes < 60,
              let seconds = Double(secondsToken),
              seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval((hours * 3_600) + (minutes * 60)) + seconds
    }
}

enum LyricsLookupPolicy {
    static let defaultOptIn = false
    static let privacyStatement = "Lyrics lookup is off until you turn it on. When enabled, Tonearm sends track title, artist, album, and duration to LRCLIB."

    enum Decision: Equatable {
        case allowed(provider: String)
        case blocked(reason: String)
    }

    static func decision(isOptedIn: Bool, provider: String = "LRCLIB") -> Decision {
        guard isOptedIn else {
            return .blocked(reason: "Lyrics lookup is off.")
        }
        return .allowed(provider: provider)
    }
}
