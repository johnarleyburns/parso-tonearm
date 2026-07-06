import SwiftUI

/// TF6: minimal create sheet — a name field plus an optional multi-select from a
/// single long list of every track in the library.
struct CreatePlaylistSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<Int64> = []
    @State private var filter = ""

    private var filteredTracks: [TrackRow] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return appState.allTracks }
        return appState.allTracks.filter {
            $0.track.title.lowercased().contains(q)
                || ($0.album?.title.lowercased().contains(q) ?? false)
                || ($0.album?.artist?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("New Playlist").font(.system(size: 19, weight: .bold)).padding(.top, 12)

            TextField("", text: $name, prompt: Text("Playlist name").foregroundStyle(Palette.ink3))
                .font(.system(size: 15, weight: .medium))
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 14).frame(height: 46)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
                .padding(.top, 16)

            HStack {
                Text(selected.isEmpty ? "Add tracks (optional)" : "\(selected.count) selected")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink2)
                Spacer()
            }
            .padding(.top, 16).padding(.bottom, 8)

            SearchField(text: $filter, placeholder: "Filter library…")
                .padding(.bottom, 10)

            List {
                ForEach(filteredTracks) { row in
                    Button { toggle(row.id) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(row.id) ? Palette.brass : Palette.ink3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.track.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(row.album?.artist ?? row.album?.title ?? "")
                                    .font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Palette.hairline)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button {
                Task {
                    await appState.createPlaylist(title: name, trackIds: orderedSelection())
                    dismiss()
                }
            } label: {
                Text("Create Playlist")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Color(hex: 0x221503))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(LinearGradient(colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                               startPoint: .top, endPoint: .bottom), in: Capsule())
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func orderedSelection() -> [Int64] {
        appState.allTracks.map { $0.id }.filter { selected.contains($0) }
    }
}
