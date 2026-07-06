import SwiftUI

struct AddFolderSheet: View {
    let folderURL: URL
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var keepOrder = true
    @State private var includeSubfolders = true
    @State private var watch = false
    @State private var fileCount = 0
    @State private var subfolderCount = 0
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add Local Folder").font(.system(size: 19, weight: .bold)).padding(.top, 12)
            Text(folderURL.lastPathComponent).font(.system(size: 12.5)).foregroundStyle(Palette.ink2).padding(.top, 5)

            HStack(spacing: 12) {
                ArtworkView(seed: folderURL.lastPathComponent, cornerRadius: 12).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderURL.lastPathComponent).font(.system(size: 13.5, weight: .semibold))
                    Text("\(fileCount) audio files\(subfolderCount > 0 ? " · \(subfolderCount) subfolders" : "")")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                }
                Spacer()
            }
            .padding(12).glassSurface(cornerRadius: 16).padding(.top, 13)

            toggle("Keep folder order", "Off sorts by track number & name", $keepOrder).padding(.top, 13)
            toggle("Include subfolders", "Adds nested folders as sections", $includeSubfolders)
                .padding(.top, 10)
            toggle("Watch folder for changes", "Rescan on app launch", $watch).padding(.top, 10)

            Spacer(minLength: 12)

            Button {
                Task { await importFolder() }
            } label: {
                Group {
                    if isImporting { ProgressView().tint(.black) }
                    else { Text("Import \(fileCount) Files") }
                }
                .font(.system(size: 15.5, weight: .bold)).foregroundStyle(Color(hex: 0x221503))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(LinearGradient(colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                           startPoint: .top, endPoint: .bottom), in: Capsule())
            }
            .disabled(isImporting)

            Text("Files stay where they are — Platterhead keeps a secure\nbookmark and reads them in place.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center).padding(.top, 11)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
        .onChange(of: includeSubfolders) { _, _ in rescan() }
        .task { rescan() }
    }

    private func toggle(_ title: String, _ sub: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(sub).font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Palette.brassDeep)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassSurface(cornerRadius: 14)
    }

    private func rescan() {
        let files = IngestService().scanFolder(folderURL, includeSubfolders: includeSubfolders)
        fileCount = files.count
        subfolderCount = Set(files.compactMap { $0.relativeSection }).count
    }

    private func importFolder() async {
        isImporting = true
        defer { isImporting = false }
        await IngestService().addFolder(folderURL, includeSubfolders: includeSubfolders,
                                        keepOrder: keepOrder, watch: watch, into: appState.store)
        await appState.reload()
        dismiss()
        appState.tab = .playlists
    }
}
