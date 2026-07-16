import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import TonearmCore

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
                    Color.clear
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
                    Color.clear
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
        } else if family == .accessoryRectangular {
            accessoryEmpty("Nothing Playing")
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
            if nowPlaying.isPlaying, nowPlaying.duration > 0, nowPlaying.endDate > nowPlaying.startDate {
                ProgressView(timerInterval: nowPlaying.startDate...nowPlaying.endDate, countsDown: false)
                    .tint(.green)
                Text(timerInterval: nowPlaying.startDate...nowPlaying.endDate, countsDown: true)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView(value: nowPlaying.progress)
                    .tint(.green)
                HStack {
                    Image(systemName: nowPlaying.isPlaying ? "play.fill" : "pause.fill")
                    Text(nowPlaying.isPlaying ? "Playing" : "Paused")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(TonearmWidgetBackground())
    }

    private func accessory(_ nowPlaying: WidgetNowPlayingSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: nowPlaying.isPlaying ? "play.fill" : "pause.fill")
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(nowPlaying.track.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(nowPlaying.track.artist)
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    private func accessoryEmpty(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .foregroundStyle(.primary.opacity(0.5))
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
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
            if family == .accessoryRectangular {
                accessoryEmpty("No History Yet")
            } else {
                EmptyWidgetView(title: "No History Yet", subtitle: "Play something in Tonearm")
            }
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
            .background(TonearmWidgetBackground())
        }
    }

    private func accessory(_ track: WidgetTrackSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    private func accessoryEmpty(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(.primary.opacity(0.5))
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
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
            if let filename = track.artworkFilename,
               let url = WidgetArtworkStore.imageURL(for: filename),
               let data = try? Data(contentsOf: url),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: track.hasArtwork ? "music.quarternote.3" : "music.note")
                    .foregroundStyle(.white)
            }
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
            LiveActivityContentView(context: context, showsControls: true)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.green)
                .widgetURL(TonearmWidgetURL.nowPlaying)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LiveActivityContentView(context: context, showsControls: false)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        if #available(iOS 17.0, *) {
                            LiveActivityTransportControls(isPlaying: context.state.isPlaying)
                        }
                        LiveActivityProgressView(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                if context.state.duration > 0 {
                    Text("\(Int((context.state.progress * 100).rounded()))%")
                        .font(.caption2.weight(.semibold))
                } else {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                }
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.green)
            }
            .widgetURL(TonearmWidgetURL.nowPlaying)
            .keylineTint(.green)
        }
    }
}

private struct LiveActivityContentView: View {
    var context: ActivityViewContext<TonearmNowPlayingAttributes>
    var showsControls: Bool
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            if context.isStale {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Outdated")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                }
            }
            HStack(alignment: .center, spacing: 12) {
                LiveActivityArtwork(filename: state.artworkFilename, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    LiveActivityProgressView(state: state)
                }
                Image(systemName: state.isPlaying ? "play.circle.fill" : "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isLuminanceReduced ? Color.white.opacity(0.7) : Color.green)
            }
            if showsControls, #available(iOS 17.0, *) {
                LiveActivityTransportControls(isPlaying: state.isPlaying)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .unredacted()
        .privacySensitive(false)
    }
}

@available(iOS 17.0, *)
private struct LiveActivityTransportControls: View {
    var isPlaying: Bool

    var body: some View {
        HStack(spacing: 24) {
            Button(intent: TonearmPreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .tint(.white)

            Button(intent: TonearmTogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .tint(.white)

            Button(intent: TonearmNextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .tint(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveActivityProgressView: View {
    var state: TonearmNowPlayingAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if state.duration > 0, state.isPlaying, state.endDate > state.startDate {
                ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false)
                    .tint(.green)
                Text(timerInterval: state.startDate...state.endDate, countsDown: true)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            } else if state.duration > 0 {
                ProgressView(value: state.progress)
                    .tint(.green)
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isPlaying ? Color.green : Color.white.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(state.isPlaying ? "Playing" : "Paused")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }
}

private struct LiveActivityArtwork: View {
    var filename: String?
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.12))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: size, height: size)
    }

    private var image: UIImage? {
        guard let filename,
              let url = WidgetArtworkStore.imageURL(for: filename),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
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
