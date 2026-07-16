import SwiftUI
import TonearmCore

struct SourcesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: "Sources")
                        .padding(.bottom, 12)

                    if appState.sources.isEmpty {
                        EmptyStateView(icon: "cloud",
                                       title: "No sources yet",
                                       message: "Paste an archive.org link — an item, public list, favorites page, or collection.")
                            .padding(.top, 60)
                    } else {
                        ForEach(appState.sources) { source in
                            NavigationLink(value: source) {
                                SourceRow(source: source)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Play") { Task { await appState.playSource(source) } }
                                Button("Remove", role: .destructive) {
                                    Task { await appState.deleteSource(source) }
                                }
                            }
                            Divider().overlay(Palette.hairline)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 160)
            }
            .background(Palette.sourcesBackground.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .navigationDestination(for: Source.self) { source in
                SourceDetailView(source: source)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct SourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            SourceArtworkView(source: source, cornerRadius: 9)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch source.kind {
        case .local: return "On device"
        case .iaItem: return "Item · streams from archive.org"
        case .iaList: return "List · streams from archive.org"
        case .iaCollection: return "Collection · streams from archive.org"
        case .iaFavorites: return "Favorites · streams from archive.org"
        case .subsonic: return "Subsonic library"
        case .webDAV: return "WebDAV library"
        case .smb: return "SMB library"
        case .jellyfin: return "Jellyfin library"
        case .plex: return "Plex library"
        case .dropbox: return "Dropbox library"
        case .googleDrive: return "Google Drive library"
        case .oneDrive: return "OneDrive library"
        case .pCloud: return "pCloud library"
        }
    }
}
