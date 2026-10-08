import SwiftUI
import TonearmWatchCore

/// §12 — the in-app diagnostics export. Renders the redacted, per-export-hashed JSON so a tester
/// can read it aloud or transcribe it. No titles, URLs, paths, credentials, tokens, or search
/// text can appear here — `WatchDiagnosticsExport` has nowhere to carry them.
struct WatchDiagnosticsView: View {
    @State private var json = String(localized: "Loading…")
    @State private var eventCount = 0
    @State private var events: [WatchDiagnosticEvent] = []
    @State private var showRawCodes = false
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("watch.diagnostics.refresh")
                .disabled(isLoading)

                VStack(alignment: .leading, spacing: 8) {
                    if isLoading {
                        ProgressView("Loading diagnostics…")
                    } else {
                        Text("Audio receipt").font(.headline)
                        if let event = events.last(where: { $0.category == .installResult }) {
                            Text(audioSummary(event.stateCode)).font(.caption)
                            Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2)
                        } else {
                            Text("No audio receipt recorded this session.").font(.caption)
                        }
                        Text("Watch report").font(.headline)
                        if let event = events.last(where: { $0.category == .manifestConvergence }) {
                            Text(reportSummary(event.stateCode))
                                .font(.caption)
                            Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2)
                        } else {
                            Text("No watch report recorded this session.").font(.caption)
                        }
                        Text("History covers this app session, not previous launches.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("watch.diagnostics.summary")

                Button(showRawCodes ? "Hide Raw Codes" : "Show Raw Codes") {
                    showRawCodes.toggle()
                }
                .accessibilityIdentifier("watch.diagnostics.raw")
                if showRawCodes {
                    Text(json)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("watch.diagnostics.json")
                        .accessibilityValue("\(eventCount) events")
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Diagnostics")
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        events = await WatchAppAssembly.shared.diagnostics.events()
        let export = await WatchAppAssembly.shared.diagnosticsExport()
        isLoading = false
        eventCount = export.eventCount
        if let data = try? WatchDiagnosticsExporter.encode(export) {
            json = String(decoding: data, as: UTF8.self)
        } else {
            json = String(localized: "Encoding failed.")
        }
    }

    private func reportSummary(_ code: String) -> String {
        switch code {
        case "reported": "Report queued for iPhone."
        case "reportQueueFailed": "Apple did not accept the watch status report."
        default: "Could not read the watch library to report downloads."
        }
    }

    private func audioSummary(_ code: String) -> LocalizedStringKey {
        switch code {
        case "chunkReceived": "Audio chunk reached the watch."
        case "audioFileReceived": "Audio file reached the watch."
        case "chunkRetained": "Audio chunk saved and verified."
        case "inboxStagingFailed": "Received file could not be saved from Apple's inbox."
        case "installed": "Audio installed and ready to play."
        case "duplicateIgnored": "Audio was already installed."
        case "deferredAwaitingMetadata": "Audio waiting for catalog metadata."
        case "artworkInstalled", "artworkDuplicateIgnored", "artworkDeferredAwaitingMetadata": "Artwork processed; this does not confirm downloaded audio."
        case "checksumMismatch": "Received audio failed its integrity check."
        case "insufficientWatchStorage": "Not enough space to save audio."
        default: "Audio processing failed. Expand Raw Codes for details."
        }
    }
}
