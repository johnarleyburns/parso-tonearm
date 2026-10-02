import SwiftUI
import UniformTypeIdentifiers
import TonearmCore

struct AddMenuSheet: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                MenuItem(icon: "server.rack", title: String(localized: "Add Remote Library"),
                         subtitle: RemoteConnectorCatalog.proDisplayList) {
                    appState.pendingImport = nil
                    appState.showAddMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.requestAddRemoteLibrary()
                    }
                }
                Divider().overlay(Palette.hairline)
                MenuItem(icon: "folder", title: String(localized: "Add Local Folder"),
                         subtitle: String(localized: "Import a folder, keep its order")) {
                    appState.showAddMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.pendingImport = .folder
                    }
                }
                Divider().overlay(Palette.hairline)
                MenuItem(icon: "music.note", title: String(localized: "Add Audio Files"),
                         subtitle: Self.audioFilesSubtitle) {
                    appState.showAddMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.pendingImport = .files
                    }
                }
            }
            .glassSurface(cornerRadius: 20)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            #if os(macOS)
            // A Mac sheet has no swipe-down or tap-outside dismissal.
            Button("Cancel", role: .cancel) { appState.showAddMenu = false }
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 16)
            #endif
        }
        #if os(iOS)
        .presentationBackground(.clear)
        #endif
    }

    private static var audioFilesSubtitle: String {
        #if os(macOS)
        String(localized: "Pick individual tracks from Finder")
        #else
        String(localized: "Pick individual tracks from Files")
        #endif
    }
}

private struct MenuItem: View {
    let icon: String
    let title: String
    let subtitle: String
    var locked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: locked ? "lock.fill" : icon)
                    .font(Typography.headline).foregroundStyle(Palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Typography.callout).foregroundStyle(Palette.ink)
                    Text(subtitle).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locked ? String(localized: "\(title), requires Pro") : title)
        .accessibilityIdentifier(title)
    }
}
