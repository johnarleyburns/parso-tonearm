import SwiftUI
import TonearmWatchCore

struct WatchStorageView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.tracks.count) tracks")
                            .font(.system(.headline, design: .default))
                        Text(WatchTimeFmt.megabytes(model.storage?.readyBytes ?? 0))
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("iPhone") {
                HStack(spacing: 6) {
                    Image(systemName: model.phoneReachable
                          ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .foregroundStyle(model.phoneReachable ? .green : .secondary)
                    Text(model.phoneReachable ? "Connected" : "Not reachable")
                        .font(.system(.body, design: .default))
                    Spacer()
                }
                .accessibilityIdentifier("storage.phoneStatus")
                .accessibilityValue(model.phoneReachable ? "connected" : "unreachable")
            }

            if let notice = model.recoveryNotice {
                Section {
                    Text(notice)
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(model.tracks) { track in
                    HStack {
                        Text(track.title)
                            .font(.system(.body, design: .default))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Add or remove downloads from Platterhead on your iPhone.")
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Storage")
        .task { await model.refresh() }
    }
}
