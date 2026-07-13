import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private enum TonearmWidgetURL {
    static let nowPlaying = URL(string: "tonearm://now-playing")!
    static let togglePlayback = URL(string: "tonearm://toggle-playback")!
    static let next = URL(string: "tonearm://next")!
    static let previous = URL(string: "tonearm://previous")!
}

struct TonearmWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var state: WidgetTimelineState
}

struct TonearmTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TonearmWidgetEntry {
        TonearmWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshotBuilder.build(
                playback: .init(
                    track: .init(
                        id: 1,
                        title: "Nocturne in E-flat major",
                        artist: "Tonearm",
                        albumTitle: "Recently Played",
                        duration: 262,
                        artworkID: nil
                    ),
                    isPlaying: true,
                    elapsed: 84,
                    duration: 262
                ),
                recentlyPlayed: [
                    .init(id: 2, title: "Piano Sonata No. 14", artist: "Beethoven", albumTitle: nil, duration: 905, artworkID: nil),
                    .init(id: 3, title: "Clair de lune", artist: "Debussy", albumTitle: nil, duration: 318, artworkID: nil)
                ],
                now: Date()
            ),
            state: .fresh
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TonearmWidgetEntry) -> Void) {
        let now = Date()
        let entry = WidgetSnapshotTimeline.entry(for: WidgetSnapshotStore.load(now: now), now: now)
        completion(TonearmWidgetEntry(date: entry.date, snapshot: entry.snapshot, state: entry.state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TonearmWidgetEntry>) -> Void) {
        let now = Date()
        let entry = WidgetSnapshotTimeline.entry(for: WidgetSnapshotStore.load(now: now), now: now)
        completion(Timeline(
            entries: [TonearmWidgetEntry(date: entry.date, snapshot: entry.snapshot, state: entry.state)],
            policy: .after(entry.nextRefreshDate)
        ))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "guru.parso.tonearm.now-playing", provider: TonearmTimelineProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    TonearmWidgetBackground()
                }
                .widgetURL(TonearmWidgetURL.nowPlaying)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the current Tonearm track.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "guru.parso.tonearm.recently-played", provider: TonearmTimelineProvider()) { entry in
            RecentlyPlayedWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    TonearmWidgetBackground()
                }
                .widgetURL(TonearmWidgetURL.nowPlaying)
        }
        .configurationDisplayName("Recently Played")
        .description("Shows recent Tonearm tracks.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct NowPlayingWidgetView: View {
    var entry: TonearmWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let nowPlaying = entry.snapshot.nowPlaying {
            switch family {
            case .accessoryRectangular:
                accessory(nowPlaying)
            default:
                standard(nowPlaying)
            }
        } else {
            EmptyWidgetView(title: "Nothing Playing", subtitle: "Open Tonearm")
        }
    }

    private func standard(_ nowPlaying: WidgetNowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ArtworkBadge(track: nowPlaying.track, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlaying.track.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(nowPlaying.track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            ProgressView(value: nowPlaying.progress)
                .tint(.green)
            HStack {
                Image(systemName: nowPlaying.isPlaying ? "play.fill" : "pause.fill")
                Text(nowPlaying.isPlaying ? "Playing" : "Paused")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func accessory(_ nowPlaying: WidgetNowPlayingSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: nowPlaying.isPlaying ? "play.fill" : "pause.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text(nowPlaying.track.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(nowPlaying.track.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct RecentlyPlayedWidgetView: View {
    var entry: TonearmWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let rows = entry.snapshot.recentlyPlayed
        if rows.isEmpty {
            EmptyWidgetView(title: "No History Yet", subtitle: "Play something in Tonearm")
        } else if family == .accessoryRectangular {
            accessory(rows[0])
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recently Played")
                    .font(.headline)
                ForEach(rows, id: \.stableID) { track in
                    HStack(spacing: 8) {
                        ArtworkBadge(track: track, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    private func accessory(_ track: WidgetTrackSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct EmptyWidgetView: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "music.note")
                .font(.title2)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding()
    }
}

private struct ArtworkBadge: View {
    var track: WidgetTrackSnapshot
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(track.hasArtwork ? Color.green.opacity(0.45) : Color.white.opacity(0.12))
            Image(systemName: track.hasArtwork ? "music.quarternote.3" : "music.note")
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct TonearmWidgetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.07),
                Color(red: 0.04, green: 0.18, blue: 0.14),
                Color(red: 0.18, green: 0.13, blue: 0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct TonearmNowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TonearmNowPlayingAttributes.self) { context in
            LiveActivityContentView(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.green)
                .widgetURL(TonearmWidgetURL.nowPlaying)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LiveActivityContentView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(.green)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text("\(Int((context.state.progress * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.green)
            }
            .widgetURL(TonearmWidgetURL.nowPlaying)
        }
    }
}

private struct LiveActivityContentView: View {
    var state: TonearmNowPlayingAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.isPlaying ? "play.circle.fill" : "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: state.progress)
                    .tint(.green)
            }
        }
        .padding()
    }
}

@available(iOS 18.0, *)
struct TonearmPlaybackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.parso.tonearm.control.toggle") {
            ControlWidgetButton(action: OpenURLIntent(TonearmWidgetURL.togglePlayback)) {
                Label("Play/Pause", systemImage: "playpause.fill")
            }
            .tint(.green)
        }
        .displayName("Tonearm Play/Pause")
        .description("Toggle Tonearm playback.")
    }
}

@available(iOS 18.0, *)
struct TonearmNextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.parso.tonearm.control.next") {
            ControlWidgetButton(action: OpenURLIntent(TonearmWidgetURL.next)) {
                Label("Next", systemImage: "forward.fill")
            }
            .tint(.green)
        }
        .displayName("Tonearm Next")
        .description("Skip to the next Tonearm track.")
    }
}

@available(iOS 18.0, *)
struct TonearmPreviousTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.parso.tonearm.control.previous") {
            ControlWidgetButton(action: OpenURLIntent(TonearmWidgetURL.previous)) {
                Label("Previous", systemImage: "backward.fill")
            }
            .tint(.green)
        }
        .displayName("Tonearm Previous")
        .description("Return to the previous Tonearm track.")
    }
}

@main
struct TonearmWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
        TonearmNowPlayingLiveActivity()
        if #available(iOS 18.0, *) {
            TonearmPlaybackControl()
            TonearmNextTrackControl()
            TonearmPreviousTrackControl()
        }
    }
}
