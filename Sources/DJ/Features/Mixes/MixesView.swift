import SwiftUI

/// The Recorded Mixes screen (mockup `ipad/10`, §41.12; plan 5.12): every
/// finished mix as a card — title, date, duration, track count, size and the
/// honest where-it-is state — plus the storage readout. Selecting a mix opens
/// the finish screen for replay (FR-REC-5, FR-REC-6). Recordings are user
/// content and are **never auto-evicted** (§43.6) — the app asks, never chooses.
public struct MixesView: View {
    @StateObject private var model: MixesModel
    @State private var detailMix: DJMix?
    @State private var deleteRow: MixesModel.Row?

    public init(model: MixesModel = MixesModel()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.isEmpty && model.isLoaded {
                    ContentUnavailableView {
                        Label("No recorded mixes", systemImage: "waveform.badge.record")
                    } description: {
                        Text("Record a set from the workspace and it appears here, ready to play.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)],
                                  spacing: 14) {
                            ForEach(model.rows) { row in
                                mixCard(row)
                            }
                        }
                        .padding(16)

                        storageCards
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Recorded mixes")
        }
        .preferredColorScheme(.dark)
        .task { await model.begin() }
        .sheet(item: $detailMix) { mix in
            RecordingFinishView(mix: mix)
        }
        .confirmationDialog("Delete this recording?",
                            isPresented: Binding(get: { deleteRow != nil },
                                                 set: { if !$0 { deleteRow = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteRow) { row in
            Button("Delete", role: .destructive) {
                Task { await model.delete(row) }
            }
            Button("Keep", role: .cancel) {}
        } message: { row in
            Text("“\(row.mix.title)” and its audio file will be removed. This cannot be undone.")
        }
    }

    private func mixCard(_ row: MixesModel.Row) -> some View {
        let mix = row.mix
        return Button {
            detailMix = mix
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(artworkGradient(for: mix))
                    .frame(height: 84)
                    .overlay(Text("◉").font(.system(size: 26)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(mix.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(for: mix))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        statePill(mix)
                        Spacer()
                        Image(systemName: "play.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                detailMix = mix
            } label: {
                Label("Review", systemImage: "play.circle")
            }
            Button(role: .destructive) {
                deleteRow = row
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var storageCards: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage").font(.system(size: 15, weight: .semibold))
                Text("Mixes on this iPad")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(model.mixStorageText())
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Text("Mixes are never auto-evicted. They're the one thing in the app that can't be re-derived from your music — if storage gets tight we ask rather than choose.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Playback").font(.system(size: 15, weight: .semibold))
                Text("Recordings play in the free player")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("M4A · AAC 256 kbps")
                    .font(.system(size: 13, design: .monospaced))
                Text("The app names the format it records. A finished mix plays on any device, and keeps playing even if Pro isn't restored yet — recordings are yours (FR-REC-5, FR-REC-7).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func statePill(_ mix: DJMix) -> some View {
        let (text, color): (String, Color) = {
            switch mix.state {
            case .complete: return ("On this iPad", .green)
            case .corrupt: return ("Couldn't be recovered", .orange)
            case .recording: return ("In progress", .yellow)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func subtitle(for mix: DJMix) -> String {
        var parts: [String] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        parts.append(formatter.string(from: mix.recordedAt))
        parts.append(CueSheetBuilder.timestamp(mix.durationSec))
        parts.append("\(mix.trackCount) track\(mix.trackCount == 1 ? "" : "s")")
        if let size = mix.sizeBytes {
            parts.append(MixesModel.formattedBytes(size))
        }
        return parts.joined(separator: " · ")
    }

    private func artworkGradient(for mix: DJMix) -> LinearGradient {
        let index = abs(mix.title.hashValue) % 3
        switch index {
        case 0:
            return LinearGradient(colors: [Color(red: 0.18, green: 0.89, blue: 0.84),
                                           Color(red: 0.61, green: 0.4, blue: 1.0)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case 1:
            return LinearGradient(colors: [Color(red: 1.0, green: 0.54, blue: 0.36),
                                           Color(red: 0.24, green: 0.86, blue: 0.59)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [Color(red: 1.0, green: 0.81, blue: 0.31),
                                           Color(red: 0.77, green: 0.23, blue: 0.69)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
