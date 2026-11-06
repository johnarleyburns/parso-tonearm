import SwiftUI
import TonearmCore

/// "Add This Folder to My Music" — recursively collects every audio track under the folder
/// currently being browsed (and its subfolders) and imports them directly into the library, not
/// a playlist (contrast `AddRemoteTracksSheet`, which is current-folder-only and playlist-
/// targeted). Scoping to a folder is the whole point: a personal Drive can have audio scattered
/// in folders that aren't music at all (school projects, presentations) — this lets the real
/// music folder be imported in one action without either hand-tapping every track or risking
/// pulling in everything else in the account.
struct AddFolderToLibrarySheet: View {
    let source: Source
    let path: String
    let scopeTitle: String
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning
    @State private var foldersVisited = 0
    @State private var tracksFound = 0
    @State private var collectedNodes: [RemoteNode] = []
    @State private var cancelled = false
    @State private var resultText: String?

    private enum Phase: Equatable { case scanning, confirming, importing, done }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Palette.ink.opacity(0.35)).frame(width: 36, height: 5)
            Text("Add Folder to My Music").font(.headline)
            Text(scopeTitle).font(.caption).foregroundStyle(Palette.inkTertiary)

            switch phase {
            case .scanning:
                ProgressView(scanningLabel)
                    .accessibilityIdentifier("addFolder.scanning")
            case .confirming:
                Text(tracksFound == 0
                     ? String(localized: "No tracks found in this folder.")
                     : String(localized: "Add \(tracksFound) track\(tracksFound == 1 ? "" : "s") to My Music?"))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("addFolder.confirmText")
            case .importing:
                ProgressView(String(localized: "Adding \(tracksFound) tracks to My Music…"))
                    .accessibilityIdentifier("addFolder.importing")
            case .done:
                if let resultText {
                    Text(resultText).font(.caption).foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("addFolder.result")
                }
            }

            Spacer()
            HStack {
                Button(phase == .scanning ? "Cancel" : "Close") {
                    if phase == .scanning { cancelled = true } else { dismiss() }
                }
                .accessibilityIdentifier("addFolder.cancel")
                Spacer()
                if phase == .confirming, tracksFound > 0 {
                    Button("Add") { Task { await addAll() } }
                        .accessibilityIdentifier("addFolder.confirm")
                }
            }
        }
        .padding(20).foregroundStyle(Palette.ink)
        .presentationDetents([.medium]).presentationBackground(.ultraThinMaterial)
        .task { await scan() }
    }

    private var scanningLabel: String {
        String(localized: "Scanning… \(tracksFound) track\(tracksFound == 1 ? "" : "s") found in \(foldersVisited) folder\(foldersVisited == 1 ? "" : "s")")
    }

    private func scan() async {
        guard let provider = try? RemoteLibraryProviderFactory.provider(for: source) else {
            resultText = String(localized: "Couldn't reach \(source.title).")
            phase = .done
            return
        }
        let nodes = await RemoteScopePlayback.allAudioNodes(in: provider, path: path) { folders, tracks in
            foldersVisited = folders
            tracksFound = tracks
        }
        guard !cancelled, !Task.isCancelled else {
            dismiss()
            return
        }
        collectedNodes = nodes
        phase = .confirming
    }

    private func addAll() async {
        phase = .importing
        guard let provider = try? RemoteLibraryProviderFactory.provider(for: source) else {
            resultText = String(localized: "Couldn't reach \(source.title).")
            phase = .done
            return
        }
        let result = await RemotePlaylistIngest.persist(
            nodes: collectedNodes, resolve: { try await provider.resolve(node: $0) },
            source: source, store: appState.store)
        await appState.reload()
        resultText = result.skipped > 0
            ? String(localized: "\(result.trackIDs.count) added · \(result.skipped) unavailable")
            : String(localized: "\(result.trackIDs.count) added to My Music")
        phase = .done
    }
}
