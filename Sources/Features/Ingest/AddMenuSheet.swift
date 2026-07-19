import SwiftUI
import UniformTypeIdentifiers
import TonearmCore

struct AddMenuSheet: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                MenuItem(icon: "server.rack", title: "Add Remote Library",
                         subtitle: RemoteConnectorCatalog.proDisplayList,
                         locked: !ProGating.isEnabled(.remoteLibraries)) {
                    appState.pendingImport = nil
                    appState.showAddMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.requestAddRemoteLibrary()
                    }
                }
                Divider().overlay(Palette.hairline)
                MenuItem(icon: "folder", title: "Add Local Folder",
                         subtitle: "Import a folder, keep its order") {
                    appState.showAddMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.pendingImport = .folder
                    }
                }
                Divider().overlay(Palette.hairline)
                MenuItem(icon: "music.note", title: "Add Audio Files",
                         subtitle: "Pick individual tracks from Files") {
                    appState.showAddMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.pendingImport = .files
                    }
                }
            }
            .glassSurface(cornerRadius: 20)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .presentationBackground(.clear)
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
                    .font(.system(size: 17)).foregroundStyle(Palette.brass)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
                }
                Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locked ? "\(title), requires Pro" : title)
        .accessibilityIdentifier(title)
    }
}
