import SwiftUI
import TonearmWatchLegacyCore

struct WatchStorageView: View {
    @State private var entries: [LegacyWatchManifestRecord] = []
    @State private var titles: [String: String] = [:]
    @State private var showRemoveAllConfirm = false
    @ObservedObject private var session = WatchSessionAdapter.shared

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entries.count) tracks")
                            .font(.system(.headline, design: .default))
                        Text(totalBytes)
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("iPhone") {
                HStack(spacing: 6) {
                    Image(systemName: session.isReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .foregroundStyle(session.isReachable ? .green : .secondary)
                    Text(session.isReachable ? "Connected" : "Not reachable")
                        .font(.system(.body, design: .default))
                    Spacer()
                }
                .accessibilityIdentifier("storage.phoneStatus")
                .accessibilityValue(session.isReachable ? "connected" : "unreachable")
            }

            Section {
                ForEach(entries, id: \.trackKey) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trackTitle(for: entry.trackKey))
                                .font(.system(.body, design: .default))
                                .lineLimit(1)
                            Text(entry.pinned ? "Pinned" : "Cached")
                                .font(.system(.caption2))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(WatchTimeFmt.megabytes(entry.bytes))
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    remove(at: offsets)
                }
            }

            Section {
                Button(role: .destructive) {
                    showRemoveAllConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Remove All")
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Storage")
        .task { await load() }
        .alert("Remove All", isPresented: $showRemoveAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) {
                Task {
                    try? await LegacyWatchLibraryStore.shared.removeAllManifests()
                    await load()
                }
            }
        } message: {
            Text("Remove all downloaded music from this watch?")
        }
    }

    private var totalBytes: String {
        let total = entries.reduce(0) { $0 + $1.bytes }
        return WatchTimeFmt.megabytes(total)
    }

    private func trackTitle(for key: String) -> String { titles[key] ?? key }

    private func load() async {
        entries = (try? await LegacyWatchLibraryStore.shared.manifests()) ?? []
        var resolved: [String: String] = [:]
        for entry in entries {
            resolved[entry.trackKey] = await LegacyWatchLibraryStore.shared.title(forTrackKey: entry.trackKey)
        }
        titles = resolved
    }

    private func remove(at offsets: IndexSet) {
        let toRemove = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        Task {
            try? await LegacyWatchLibraryStore.shared.removeManifest(keys: toRemove.map(\.trackKey))
        }
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
