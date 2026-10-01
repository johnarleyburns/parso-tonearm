import SwiftUI
import TonearmCore

struct AddFolderSheet: View {
    let folderURL: URL
    let folderBookmark: Data?
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var keepOrder = true
    @State private var includeSubfolders = true
    @State private var watch = false
    @State private var fileCount = 0
    @State private var subfolderCount = 0
    @State private var isImporting = false
    @State private var scanError: String?
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.ink.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add Local Folder").font(Typography.headline).padding(.top, 12)
            Text(folderURL.lastPathComponent).font(Typography.callout).foregroundStyle(Palette.inkSecondary).padding(.top, 5)

                HStack(spacing: 12) {
                ArtworkView(seed: folderURL.lastPathComponent, cornerRadius: 12).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderURL.lastPathComponent).font(Typography.callout)
                    if let err = scanError {
                        Text(err).font(Typography.caption).foregroundStyle(Palette.danger)
                    } else {
                        Text(subfolderCount > 0 ? "\(fileCount) audio files · \(subfolderCount) subfolders" : "\(fileCount) audio files")
                            .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
                Spacer()
            }
            .padding(12).glassSurface(cornerRadius: 16).padding(.top, 13)

            toggle("Keep folder order", "Off sorts by track number & name", $keepOrder).padding(.top, 13)
            toggle("Include subfolders", "Adds nested folders as sections", $includeSubfolders)
                .padding(.top, 10)
            watchToggle.padding(.top, 10)

            Spacer(minLength: 12)

            Button {
                Task { await importFolder() }
            } label: {
                Group {
                    if isImporting { ProgressView().tint(Palette.accentOnFill) }
                    else { Text("Import \(fileCount) Files") }
                }
                .font(Typography.body).foregroundStyle(Palette.accentOnFill)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(LinearGradient(colors: [Palette.accent, Palette.accent],
                                           startPoint: .top, endPoint: .bottom), in: Capsule())
            }
            .disabled(isImporting)

            if let err = importError {
                Text(err).font(Typography.caption).foregroundStyle(Palette.danger).padding(.top, 8)
            }

            Text("Files stay where they are — Platterhead keeps a secure\nbookmark and reads them in place.")
                .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center).padding(.top, 11)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
        .onChange(of: includeSubfolders) { _, _ in rescan() }
        .task { rescan() }
    }

    private var watchToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Watch folder for changes").font(Typography.callout)
                Text("New files appear automatically")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            Toggle("", isOn: $watch).labelsHidden().tint(Palette.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassSurface(cornerRadius: 14)
    }

    private func toggle(_ title: LocalizedStringKey, _ sub: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.callout)
                Text(sub).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Palette.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassSurface(cornerRadius: 14)
    }

    private func resolvedURL() -> URL? {
        guard let bookmark = folderBookmark else { return nil }
        guard let (resolved, _) = BookmarkVault.resolve(bookmark) else { return nil }
        _ = resolved.startAccessingSecurityScopedResource()
        return resolved
    }

    private func rescan() {
        scanError = nil
        let url = resolvedURL()
        guard let url else {
            scanError = String(localized: "Lost access to folder")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let files = IngestService().scanFolder(url, includeSubfolders: includeSubfolders)
        fileCount = files.count
        subfolderCount = Set(files.compactMap { $0.relativeSection }).count
        if files.isEmpty && fileCount == 0 {
            scanError = String(localized: "No audio files found")
        }
    }

    private func importFolder() async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        guard let url = resolvedURL() else {
            importError = String(localized: "Lost access to folder")
            AppLogger.ingest.error("Import folder failed: cannot resolve bookmark")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let summary = try await IngestService().addFolder(
                url, includeSubfolders: includeSubfolders,
                keepOrder: keepOrder, watch: watch, into: appState.store)
            await appState.reload()
            dismiss()
            appState.tab = .myMusic
            if summary.skippedDuplicates > 0 {
                ToastCenter.shared.info(
                    "Imported \(summary.imported), skipped \(summary.skippedDuplicates) "
                        + "already in your library")
            }
        } catch {
            importError = error.localizedDescription
            AppLogger.ingest.error("Import folder failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
