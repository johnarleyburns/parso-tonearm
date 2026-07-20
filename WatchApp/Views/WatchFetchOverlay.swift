import SwiftUI

struct WatchFetchOverlay: View {
    let trackTitle: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Fetching…")
                .font(.system(.headline, design: .default))
                .fontWeight(.semibold)

            Text(trackTitle)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)

            ProgressView(value: max(0, min(1, progress)))
                .tint(.accentColor)
                .padding(.horizontal, 24)

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
