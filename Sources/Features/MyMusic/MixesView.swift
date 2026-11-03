import AVFoundation
import SwiftUI
import TonearmCore

/// My Music > Mixes: recordings saved from the manual DJ console's REC button. Loading, empty and
/// issue states never hide mixes that did load.
struct MixesView: View {
    @EnvironmentObject var appState: AppState
    @State private var mixes: [MixRecordingDocument] = []
    @State private var issues: [MixRecordingRepository.LoadIssue] = []
    @State private var didLoad = false
    @State private var selected: MixRecordingDocument?

    var body: some View {
        List {
            ForEach(issues.indices, id: \.self) { i in
                Label(Self.describe(issues[i]), systemImage: "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityIdentifier("mixes.issue")
            }
            if !didLoad {
                ProgressView().accessibilityIdentifier("mixes.loading")
            } else if mixes.isEmpty {
                Text("No mixes yet. Use REC on the DJ console to record one.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityIdentifier("mixes.empty")
            }
            ForEach(mixes) { mix in
                Button { selected = mix } label: {
                    HStack {
                        Text(mix.title)
                        Spacer()
                        Text(Self.duration(mix.durationSec))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                .accessibilityIdentifier("mixes.row")
            }
        }
        .listStyle(.plain)
        .task { await reload() }
        .sheet(item: $selected, onDismiss: { Task { await reload() } }) { mix in
            MixDetailView(mix: mix)
        }
    }

    private func reload() async {
        let snapshot = await appState.mixRecordingRepository.load()
        mixes = snapshot.mixes
        issues = snapshot.issues
        didLoad = true
    }

    static func describe(_ issue: MixRecordingRepository.LoadIssue) -> String {
        switch issue {
        case .malformedQuarantined: String(localized: "Mixes could not be read; the file was kept aside.")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }
}

struct MixDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State var mix: MixRecordingDocument
    @State private var confirmRemove = false
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tonearm/Mixes", isDirectory: true)
            .appendingPathComponent(mix.fileRelPath)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Recorded \(mix.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Duration \(MixesView.duration(mix.durationSec))")
                }
                Section {
                    Button(isPlaying ? "Pause" : "Play") { togglePlay() }
                        .accessibilityIdentifier("mixdetail.play")
                    Button("Remove Mix", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle(mix.title)
            .confirmationDialog("Remove this mix?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    player?.pause()
                    Task {
                        try? await appState.mixRecordingRepository.remove(id: mix.id)
                        try? FileManager.default.removeItem(at: fileURL)
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { player?.pause() }
    }

    private func togglePlay() {
        if player == nil { player = AVPlayer(url: fileURL) }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }
}
