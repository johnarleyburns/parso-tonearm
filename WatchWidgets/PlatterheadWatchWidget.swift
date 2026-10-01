import AppIntents
import SwiftUI
import WidgetKit
import TonearmWatchCore

/// Watch redesign A2 — the Smart Stack card: what's playing (on either device), where, a live
/// progress line, and play/pause. Tapping the card opens Now Playing.
struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: WatchNowPlayingWidgetState?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), state: WatchNowPlayingWidgetState(
            title: "Tomorrow Never Knows", subtitle: "The Beatles",
            target: .watch, isPlaying: true, elapsed: 72, duration: 178, anchorDate: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NowPlayingEntry(date: Date(), state: WatchNowPlayingWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let state = WatchNowPlayingWidgetStore.load()
        // The app reloads on every structural change; this refresh only retires a finished item.
        let refresh = state.map { $0.isPlaying ? max(Date().addingTimeInterval(60), $0.endDate) : Date().addingTimeInterval(1800) }
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [NowPlayingEntry(date: Date(), state: state)], policy: .after(refresh)))
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let state = entry.state {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(state.target == .iPhone ? String(localized: "iPhone") : String(localized: "Watch"),
                          systemImage: state.target == .iPhone ? "iphone" : "applewatch")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(state.title).font(.headline).lineLimit(1)
                    if state.isPlaying {
                        ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: { EmptyView() }
                        .tint(accent)
                    } else {
                        ProgressView(value: min(1, state.elapsed / max(state.duration, 1)))
                            .tint(accent)
                    }
                }
                Button(intent: ToggleWatchPlaybackIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .accessibilityLabel(state.isPlaying ? Text("Pause") : Text("Play"))
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("Platterhead", systemImage: "music.note").font(.caption2.weight(.semibold)).foregroundStyle(accent)
                Text("Nothing playing").font(.headline)
            }
        }
    }

    private var accent: Color { Color(red: 0xE3 / 255, green: 0xA4 / 255, blue: 0x4B / 255) }
}

struct PlatterheadNowPlayingWidget: Widget {
    let kind = "PlatterheadWatchNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(URL(string: "platterhead-watch://now-playing"))
        }
        .configurationDisplayName("Now Playing")
        .description("What Platterhead is playing, on your watch or iPhone.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct PlatterheadWatchWidgets: WidgetBundle {
    var body: some Widget {
        PlatterheadNowPlayingWidget()
    }
}
