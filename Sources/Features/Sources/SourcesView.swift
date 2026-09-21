import SwiftUI
import TonearmCore

/// A zero-configuration "Services" entry, distinct from a persisted `Source`
/// (see `JamendoBrowseView`'s doc comment) — its own navigation value so it
/// can push alongside `Source` on the same stack without pretending to be one.
enum LibraryService: String, Hashable, Identifiable {
    case jamendo
    var id: String { rawValue }
    var title: String { "Jamendo" }
}

struct SourcesView: View {
    @EnvironmentObject var appState: AppState
    /// Settings already owns a `NavigationStack` when pushing this as
    /// "Music Libraries" — a second nested stack there makes the push
    /// unstable (same reasoning as `LibraryView.ownsNavigationStack`).
    private let ownsNavigationStack: Bool

    init(ownsNavigationStack: Bool = true) {
        self.ownsNavigationStack = ownsNavigationStack
    }

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: "Libraries")
                        .padding(.bottom, 12)

                    SectionHeader(title: "Services")
                    NavigationLink(value: LibraryService.jamendo) {
                        LibraryServiceRow(service: .jamendo)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("Service Jamendo")
                    Divider().overlay(Palette.hairline)

                    SectionHeader(title: "Personal")
                        .padding(.top, 18)

                    if appState.sources.isEmpty {
                        EmptyStateView(icon: "cloud",
                                       title: "No libraries yet",
                                       message: "Paste an archive.org link, add a local folder, or connect a remote library.")
                            .padding(.top, 40)
                    } else {
                        ForEach(appState.sources) { source in
                            NavigationLink(value: source) {
                                SourceRow(source: source)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("Source \(source.title)")
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
            .navigationDestination(for: LibraryService.self) { service in
                switch service {
                case .jamendo: JamendoBrowseView()
                }
            }
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
    }
}

struct LibraryServiceRow: View {
    let service: LibraryService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.brass)
                .frame(width: 42, height: 42)
                .glassSurface(cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text("Browse by genre or search · streams from Jamendo")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
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
        case .subsonic, .webDAV, .smb, .jellyfin, .plex, .dropbox, .googleDrive, .oneDrive, .pCloud, .jamendoGenre:
            return "\(RemoteConnectorCatalog.connector(for: source.kind)?.title ?? "Remote") library"
        }
    }
}
