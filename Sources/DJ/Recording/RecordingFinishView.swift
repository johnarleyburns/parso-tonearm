import SwiftUI
import UniformTypeIdentifiers

/// The recording-finish screen (mockup `ipad/09`, §41.11; plan 5.12). Opened
/// the instant a recording finalises (FR-REC-6) and from the Mixes view
/// (FR-REC-5): title/notes, the §37.4 timeline, the **review listen** — the
/// finished mix playable in place with a seekable waveform and tappable
/// transition markers — attribution (§18A.5), and export (FR-REC-4). The
/// format is named honestly (FR-REC-7): M4A · AAC 256 kbps, never MP3.
public struct RecordingFinishView: View {
    @StateObject private var model: RecordingFinishModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSaveToFiles = false
    @State private var showDeleteConfirmation = false
    @State private var savedToast = false

    public init(mix: DJMix) {
        _model = StateObject(wrappedValue: RecordingFinishModel.makeModel(mix: mix))
    }

    public init(model: RecordingFinishModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    pills
                    reviewListen
                    timeline
                    if !model.timeline.isEmpty {
                        attribution
                    }
                    destination
                    actions
                }
                .padding(20)
            }
            .navigationTitle("Recording finished")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.begin() }
        .onReceive(timer) { _ in model.tick() }
        .fileExporter(isPresented: $showSaveToFiles,
                      item: model.assetURLForExport,
                      contentTypes: [.audio],
                      defaultFilename: model.sanitizedFilename) { _ in
            savedToast = true
        }
        .overlay(alignment: .bottom) {
            if savedToast {
                Text("Saved")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            withAnimation { savedToast = false }
                        }
                    }
            }
        }
        .alert("Delete this recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete()
                    dismiss()
                }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The mix and its audio file will be removed. This cannot be undone.")
        }
    }

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    // MARK: Header — title/notes (FR-REC-1)

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 13)
                .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.89, blue: 0.84),
                                              Color(red: 0.61, green: 0.4, blue: 1.0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 96, height: 96)
                .overlay(Text("◉").font(.system(size: 30)))
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $model.title)
                    .font(.system(size: 17, weight: .semibold))
                TextField("Notes", text: $model.notes, axis: .vertical)
                    .font(.system(size: 13))
                    .lineLimit(2...4)
                    .foregroundStyle(.secondary)
            }
        }
        .onSubmit { Task { await model.save() } }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            pill(model.durationText)
            pill(model.formatLabel) // FR-REC-7 — names the real format
            if let size = model.sizeBytes { pill(model.sizeText(size)) }
            if let rate = model.sampleRate {
                pill("\(Int(rate / 1000)) kHz \(model.channelCount == 1 ? "mono" : "stereo")")
            }
            if model.isCorrupt {
                pill("Couldn't be recovered", color: .orange)
            }
        }
    }

    // MARK: The review listen (FR-REC-6)

    private var reviewListen: some View {
        Card {
            if let error = model.loadError, model.assetURLForExport == nil {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17))
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isPlaying ? "Pause review listen" : "Play review listen")

                    VStack(alignment: .leading, spacing: 5) {
                        ReviewListenWaveform(model: model.waveform,
                                             markers: model.markers,
                                             currentTime: model.currentTime,
                                             duration: model.duration) { time in
                            model.seek(to: time)
                        }
                        HStack {
                            Text(model.timeText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Green marks are your transitions — tap one to jump to it")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(model.durationText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Timeline (§37.4)

    private var timeline: some View {
        Card {
            HStack {
                Text("Timeline").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(model.timeline.count) tracks")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if model.timeline.isEmpty {
                Text("No track events were captured for this recording.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.timeline) { event in
                        HStack(spacing: 10) {
                            Text(Self.timestamp(event.startOffsetSec))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let artist = event.artist, !artist.isEmpty {
                                    Text(artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if let bpm = event.bpmAtPlay {
                                Text(String(format: "%.1f", bpm)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if let camelot = event.camelotAtPlay {
                                Text(camelot).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                            Button {
                                model.jump(to: event.startOffsetSec)
                            } label: {
                                Image(systemName: "arrowtriangle.right.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to \(event.title)")
                        }
                        .padding(.vertical, 7)
                        if event.id != model.timeline.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    // MARK: Attribution (§18A.5)

    private var attribution: some View {
        Card {
            Text("Attribution").font(.system(size: 15, weight: .semibold))
            ForEach(Array(model.attributionLines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(model.attributionNote)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    // MARK: Destination & export (FR-REC-4)

    private var destination: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved to this iPad")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Recordings are yours — they play in the free player forever, even if Pro isn't restored on a device yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.4)

            Toggle(isOn: $model.includeCueSheet) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include tracklist / cue sheet").font(.system(size: 13))
                    Text("Artist and licence attribution travel with the share (FR-REC-4).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.green)

            HStack(spacing: 10) {
                Button {
                    showSaveToFiles = true
                } label: {
                    Label("Save to Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(items: model.shareItems) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(model.assetURLForExport == nil)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showDeleteConfirmation = true
            } label: {
                Text("Delete")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .disabled(model.assetURLForExport == nil && model.isCorrupt == false)
        }
    }

    // MARK: - Reusable bits

    private func pill(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Small pieces

/// A rounded card matching the app's dark surfaces (mockup idiom).
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// A simple wrapping row for the format/size pills.

/// The review-listen waveform: the mix's peak overview with tappable green
/// transition markers and the live playhead. Scrubbing seeks (FR-REC-6).
private struct ReviewListenWaveform: View {
    let model: MixWaveformModel?
    let markers: [TimeInterval]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let safe = size.width - 6
                guard let model, model.binCount > 0, model.duration > 0 else {
                    context.fill(Path(CGRect(x: 0, y: size.height * 0.2,
                                             width: size.width, height: size.height * 0.6)),
                                 with: .color(Color.white.opacity(0.05)))
                    return
                }
                let binWidth = safe / CGFloat(model.binCount)
                for (index, peak) in model.peaks.enumerated() {
                    let h = max(2, CGFloat(peak) * size.height * 0.8)
                    let rect = CGRect(x: 3 + CGFloat(index) * binWidth,
                                      y: (size.height - h) / 2,
                                      width: max(1, binWidth * 0.8),
                                      height: h)
                    context.fill(Path(rect), with: .color(Color.white.opacity(0.55)))
                }
                for marker in markers {
                    let x = 3 + safe * CGFloat(marker / duration)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 2)
                }
                let playX = 3 + safe * CGFloat(max(0, min(1, currentTime / duration)))
                var playhead = Path()
                playhead.move(to: CGPoint(x: playX, y: 0))
                playhead.addLine(to: CGPoint(x: playX, y: size.height))
                context.stroke(playhead, with: .color(.white), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let fraction = value.location.x / geo.size.width
                        onSeek(max(0, min(1, fraction)) * duration)
                    }
            )
        }
        .frame(height: 44)
    }
}
