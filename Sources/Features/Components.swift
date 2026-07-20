import SwiftUI
import TonearmCore

struct ScreenHeader: View {
    let title: String
    var showAdd = true
    var addAction: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 31, weight: .heavy, design: .default))
                .kerning(-0.5)
            Spacer()
            if showAdd {
                Button {
                    if let addAction { addAction() } else { appState.showAddMenu = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.brass)
                        .frame(width: 33, height: 33)
                        .glassSurface(cornerRadius: 16.5)
                }
                .accessibilityLabel("Add")
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.ink3)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.ink3))
                .foregroundStyle(Palette.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .glassSurface(cornerRadius: 20)
    }
}

struct AddRemoteLibraryButton: View {
    @EnvironmentObject var appState: AppState
    var compact = false

    private var isLocked: Bool {
        !ProGating.isEnabled(.remoteLibraries)
    }

    var body: some View {
        Button {
            appState.requestAddRemoteLibrary()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isLocked ? "lock.fill" : "server.rack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.brass)
                    .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
                    .glassSurface(cornerRadius: compact ? 15 : 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Remote Library")
                        .font(.system(size: compact ? 13 : 13.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(RemoteConnectorCatalog.proDisplayList)
                        .font(.system(size: compact ? 10.5 : 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 10 : 12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLocked ? "Add Remote Library, requires Pro" : "Add Remote Library")
        .accessibilityIdentifier("Add Remote Library")
    }
}

/// Renders a source's representative artwork: real cover art for IA sources,
/// embedded art for local sources, falling back to a per-kind icon over the
/// seed gradient when no artwork is available.
struct SourceArtworkView: View {
    let source: Source
    var cornerRadius: CGFloat = 12
    @EnvironmentObject var appState: AppState
    @State private var resolved: AppState.ResolvedSourceArtwork?

    var body: some View {
        ArtworkView(identifier: resolved?.identifier,
                    trackRow: resolved?.trackRow,
                    seed: source.title,
                    cornerRadius: cornerRadius,
                    fallbackIcon: resolved?.fallbackIcon ?? source.fallbackIcon)
            .task(id: source.id) {
                resolved = await appState.resolvedArtwork(for: source)
            }
    }
}

struct ProvenanceChip: View {
    let source: Source?
    var body: some View {
        let (icon, text) = badge
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text)
        }
        .font(.system(size: 8.5, weight: .bold))
        .kerning(0.5)
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.black.opacity(0.45), in: Capsule())
    }

    private var badge: (String, String) {
        switch source?.kind {
        case .local, .none: return ("iphone", "ON DEVICE")
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            return ("cloud", "ARCHIVE.ORG")
        case .subsonic, .webDAV, .smb, .jellyfin, .plex,
             .dropbox, .googleDrive, .oneDrive, .pCloud:
            return ("network", "REMOTE")
        }
    }
}

struct TrackRowView: View {
    let row: TrackRow
    var showCacheGlyph = true
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(row.asset?.unsupportedReason != nil ? Palette.ink3 : Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task { await appState.toggleFavorite(row) }
            } label: {
                Image(systemName: appState.isFavorite(row) ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(appState.isFavorite(row) ? Color.red : Palette.ink3)
            }
            .buttonStyle(.plain)
            let watchState = appState.watchGlyphState(for: row)
            if watchState != .notOnWatch {
                watchGlyph
            }
            if showCacheGlyph, row.asset?.kind == .remote {
                cacheGlyph
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var titleLine: String {
        if let n = row.track.trackNo { return "\(n) · \(row.track.title)" }
        return row.track.title
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = row.track.durationSec { parts.append(TimeFmt.mmss(d)) }
        if let codec = row.track.codec { parts.append(codec) }
        if let reason = row.asset?.unsupportedReason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var cacheGlyph: some View {
        let isCurrent = player.currentTrack?.id == row.id
        CacheGlyph(state: isCurrent ? player.cacheState : .none)
    }

    @ViewBuilder private var watchGlyph: some View {
        let state = appState.watchGlyphState(for: row)
        WatchGlyphView(state: state)
    }
}

enum TimeFmt {
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

struct TrackContextMenu: ViewModifier {
    let row: TrackRow
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { player.playSingle(row) } label: { Label("Play", systemImage: "play.fill") }
            Button { player.insertNext(row) } label: {
                Label("Play Next", systemImage: "arrowshape.turn.up.right.fill")
            }
            Button { player.appendToQueue(row) } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Divider()
            Button {
                appState.artworkChangeTrackId = row.id
            } label: {
                Label("Change Artwork", systemImage: "photo.badge.plus")
            }
            Button {
                Task { await appState.toggleFavorite(row) }
            } label: {
                let fav = appState.isFavorite(row)
                Label(fav ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: fav ? "heart.slash" : "heart")
            }
            watchMenuItems
        }
    }

    @ViewBuilder
    private var watchMenuItems: some View {
        let state = appState.watchGlyphState(for: row)
        switch state {
        case .notOnWatch:
            Button {
                Task { await appState.downloadToWatch(rows: [row]) }
            } label: {
                Label("Download to Watch", systemImage: "applewatch")
            }
        case .onWatch:
            Button {
                Task { await appState.removeFromWatch(rows: [row]) }
            } label: {
                Label("Remove from Watch", systemImage: "applewatch.slash")
            }
        case .failed:
            Button {
                Task { await appState.downloadToWatch(rows: [row]) }
            } label: {
                Label("Retry Download to Watch", systemImage: "applewatch.radiowaves.left.and.right")
            }
        case .transferring:
            EmptyView()
        }
    }
}

extension View {
    func trackContextMenu(_ row: TrackRow) -> some View {
        modifier(TrackContextMenu(row: row))
    }
}
