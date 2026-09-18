import SwiftUI
import TonearmCore

/// Shown on tap instead of starting playback instantly (docs/plans/mood-
/// based-listening-plan.md §3.6). Owner feedback: "it seems jarring to just
/// start playing it — I expect to see details about the song first." Every
/// action here reuses an existing `AudioPlayer` call already wired to
/// today's long-press `TrackContextMenu` — this promotes them to the
/// primary tap, it does not invent new playback logic.
///
/// Wired into the Listen tab's own tap sites first (mood results, Top 10
/// Songs, Jump Back In, Favorites); rolling this out to My Music/search
/// results is a deliberate follow-up (§3.6's scope note), not done here.
struct TrackDetailCard: View {
    let row: TrackRow
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    /// "Include in current mood" only shows when a mood queue is actually
    /// active (`AudioPlayer.shared.queueSource == .mood`) — checked here,
    /// not assumed by the caller, so this card behaves correctly from
    /// every site it's presented from (§3.6's audit note).
    private var moodSource: MoodQuerySource? {
        if case .mood(let source) = player.queueSource { return source }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 34, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 14)

            HStack(spacing: 12) {
                ArtworkView(trackRow: row, seed: row.track.title, cornerRadius: 12)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                    // Plan §3.6 lists artwork/title/artist-album/duration/
                    // source as the card's fields — `subtitle` above already
                    // covers artist/album (falling back to source only when
                    // there's no artist tag), but that means duration was
                    // never shown, and source was invisible whenever a track
                    // had an artist. This line always carries both.
                    Text(durationAndSource)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            VStack(spacing: 8) {
                actionButton("Play Now", icon: "play.fill", style: .primary) {
                    player.playSingle(row)
                    dismiss()
                }
                .accessibilityIdentifier("trackDetail.playNow")

                actionButton("Play Next", icon: "arrow.turn.down.right", style: .secondary) {
                    player.insertNext(row)
                    dismiss()
                }
                .accessibilityIdentifier("trackDetail.playNext")

                actionButton("Add to Queue", icon: "text.badge.plus", style: .secondary) {
                    player.appendToQueue(row)
                    dismiss()
                }
                .accessibilityIdentifier("trackDetail.addToQueue")

                if let moodSource {
                    actionButton("Include in current mood", icon: "sparkles", style: .mood) {
                        // Additive only — see MoodQuerySource's doc comment
                        // (Sources/Audio/AudioPlayer+QueueSource.swift) and
                        // §3.6's audit note: never moreLikeThis(trackID:),
                        // which would replace the active query instead of
                        // adding to it.
                        moodSource.addPositiveTerm(row.track.title)
                        dismiss()
                    }
                    .accessibilityIdentifier("trackDetail.includeInMood")
                }

                Button("Dismiss") { dismiss() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
                    .accessibilityIdentifier("trackDetail.dismiss")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
        .background(Palette.libraryBackground.ignoresSafeArea())
    }

    private var subtitle: String {
        row.artist?.name
            ?? row.album?.artist
            ?? (row.asset?.kind == .remote ? PlaybackDisplayPolicy.providerName(for: row.source) : "On device")
    }

    /// Duration (`TimeFmt.mmss`, the same formatter `TrackContextMenu`'s row
    /// subtitle already uses — `Sources/Features/Components.swift`) plus the
    /// source, always shown regardless of whether an artist tag exists.
    private var durationAndSource: String {
        var parts: [String] = []
        if let duration = row.track.durationSec { parts.append(TimeFmt.mmss(duration)) }
        parts.append(row.asset?.kind == .remote ? PlaybackDisplayPolicy.providerName(for: row.source) : "On device")
        return parts.joined(separator: " · ")
    }

    private enum ActionStyle { case primary, secondary, mood }

    private func backgroundStyle(for style: ActionStyle) -> AnyShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(LinearGradient(colors: [Palette.brass, Palette.brassDeep],
                                                startPoint: .top, endPoint: .bottom))
        case .mood:
            return AnyShapeStyle(Palette.brass.opacity(0.12))
        case .secondary:
            return AnyShapeStyle(Color.white.opacity(0.07))
        }
    }

    private func actionButton(_ title: String, icon: String, style: ActionStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(style == .primary ? Color.black : (style == .mood ? Palette.brass : Palette.ink))
            .background(backgroundStyle(for: style), in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(style == .mood ? Palette.brass.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Presents `TrackDetailCard` as a compact bottom sheet — a shared modifier
/// so every wired tap site (§3.6) presents it identically.
extension View {
    func trackDetailSheet(for row: Binding<TrackRow?>) -> some View {
        sheet(item: row) { trackRow in
            TrackDetailCard(row: trackRow)
                .presentationDetents([.height(410)])
                .presentationBackground(.clear)
        }
    }
}
