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
                        Text(storageDetail)
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("watch.downloads.storage")
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
                .accessibilityIdentifier("watch.connection.status")
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

    private var storageDetail: String {
        guard let storage = model.storage else {
            return WatchTimeFmt.megabytes(0)
        }
        let free = storage.freeBytes > 0 ? " · \(WatchTimeFmt.megabytes(storage.freeBytes)) free" : ""
        return "\(WatchTimeFmt.megabytes(storage.readyBytes)) downloaded\(free)"
    }
}
