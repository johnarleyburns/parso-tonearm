import SwiftUI
import TonearmWatchCore

enum WatchTimeFmt {
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

struct WatchTrackRow: View {
    let track: WatchTrackSnapshot

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(.body, design: .default))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let d = track.durationSeconds { parts.append(WatchTimeFmt.mmss(d)) }
        return parts.joined(separator: " · ")
    }
}

struct WatchCollectionRow: View {
    let title: String
    let subtitle: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let img = systemImage {
                Image(systemName: img)
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .default))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

struct WatchEmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.headline, design: .default))
            Text(message)
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .listRowBackground(Color.clear)
    }
}
