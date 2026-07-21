import SwiftUI

struct WatchFetchOverlay: View {
    let trackTitle: String
    let progress: Double
    let phoneUnreachable: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(phoneUnreachable ? "Can't reach iPhone" : "Fetching…")
                .font(.system(.headline, design: .default))
                .fontWeight(.semibold)

            Text(trackTitle)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)

            if phoneUnreachable {
                Text("Check your iPhone is nearby.")
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: max(0, min(1, progress)))
                    .tint(.accentColor)
                    .padding(.horizontal, 24)
            }

            Button(role: .destructive) {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.system(.caption))
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.95))
    }
}
