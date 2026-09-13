import SwiftUI

/// The generated sequence (§41.7, mockup `ipad/05b-autoplaylist-result.html`;
/// compact class §42.4/`iphone/03-autoplaylist.html`). Free tier.
///
/// The sequence is plotted against the requested arc so a mismatch is visible
/// rather than asserted (FR-PLIST-5); every transition carries its Camelot
/// relationship and BPM delta (roughest joins visible); per-row lock / replace /
/// reject are constrained re-runs (§28A.4), not re-rolls; the footer carries the
/// total-vs-target, mean transition cost, the AT-PLIST-3 "smoother than shuffle"
/// language and the honest short-pool state (plan §2.7). FR-PLIST-10's "Blend
/// these" card is dismissible, session-scoped, and inert in M3 (StoreKit is M4).
///
/// This file holds the top-level `body` and the header sections; the arc card,
/// track list, and footer/blend-card sections are extracted into
/// `PlaylistResultView+ArcCard.swift`, `PlaylistResultView+TrackList.swift`, and
/// `PlaylistResultView+Footer.swift` respectively (`ArcPlotView` has its own
/// file). `sizeClass`, `showSavePlaylistPrompt`, `playlistTitle`, and
/// `showBlendAlert` are used from those extension files too, so they are kept
/// at the implicit internal access level rather than `private`.
public struct PlaylistResultView: View {
    @ObservedObject var model: AutoPlaylistModel
    @Environment(\.horizontalSizeClass) var sizeClass
    @State var showSavePlaylistPrompt = false
    @State private var showSaveCratePrompt = false
    @State var playlistTitle = ""
    @State private var crateName = ""
    @State var showBlendAlert = false

    public init(model: AutoPlaylistModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sizeClass == .compact { compactHeader } else { regularHeader }
            arcCard
            if sizeClass == .compact { compactChips }
            trackList
            footer
            if model.showsBlendCard { blendCard }
        }
        .alert("Save as Playlist", isPresented: $showSavePlaylistPrompt) {
            TextField("Playlist name", text: $playlistTitle)
            Button("Save") { savePlaylist() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Name this Smart Crate", isPresented: $showSaveCratePrompt) {
            TextField("e.g. Dinner set", text: $crateName)
            Button("Save") { model.saveAsSmartCrate(name: crateName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A crate is the brief, not a copy — it keeps finding new matches as your library grows.")
        }
        .alert("Platterhead DJ", isPresented: $showBlendAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Blending arrives in a later release. Everything you're doing here stays free.")
        }
    }

    // MARK: - Header

    private var regularHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.resultTitle)
                    .font(.system(size: 22, weight: .bold))
                Text("“\(model.prompt)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let seconds = model.generationSecondsText {
                Text(seconds)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.cyan.opacity(0.15), in: Capsule())
                    .foregroundStyle(.cyan)
            }
            Button {
                model.onPlay?(model.rows)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            Button {
                playlistTitle = model.resultTitle
                showSavePlaylistPrompt = true
            } label: {
                Label("Save as Playlist", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)
            Button {
                crateName = ""
                showSaveCratePrompt = true
            } label: {
                Label("Save as Smart Crate", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.resultTitle)
                .font(.system(size: 22, weight: .bold))
            Text("“\(model.prompt)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
