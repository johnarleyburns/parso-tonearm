import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Playlists")
                    .padding(.bottom, 12)

                if appState.playlists.isEmpty {
                    EmptyStateView(icon: "music.note.list",
                                   title: "No playlists yet",
                                   message: "Add a folder as a playlist, or build one from any track’s menu.")
                        .padding(.top, 60)
                } else {
                    ForEach(appState.playlists) { playlist in
                        NavigationRow(icon: playlist.kind == .folder ? "folder.fill" : "music.note.list",
                                      title: playlist.title,
                                      subtitle: playlist.kind == .folder ? "Folder playlist" : "Manual playlist")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
    }
}

struct NavigationRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.brass)
                .frame(width: 42, height: 42)
                .glassSurface(cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 8)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(Palette.ink3)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }
}
