import SwiftUI
import TonearmWatchCore

/// §9 W1/W5/W12 connection banner. Text + icon, never colour alone; never covers transport
/// controls (callers place it above content, not over it). Hidden entirely when connected.
struct WatchConnectionBanner: View {
    let banner: WatchConnectionChrome.Banner

    var body: some View {
        if banner != .connected {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("watch.connection.banner")
            .accessibilityValue(banner.rawValue)
        }
    }

    private var icon: String {
        switch banner {
        case .connected: "iphone.radiowaves.left.and.right"
        case .temporarilyUnavailable: "iphone.gen3.slash"
        case .unavailable: "iphone.slash"
        case .incompatible: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch banner {
        case .connected: .green
        case .temporarilyUnavailable: .yellow
        case .unavailable, .incompatible: .secondary
        }
    }

    private var text: String {
        switch banner {
        case .connected: ""
        case .temporarilyUnavailable: "iPhone temporarily unavailable"
        case .unavailable: "iPhone unavailable — showing music on this watch"
        case .incompatible: "Update Platterhead on iPhone to sync — downloaded music still plays"
        }
    }
}
