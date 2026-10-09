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
                    reload()
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
                        Text("Last native delivery").font(.headline)
                        if let event = events.last(where: { $0.stateCode.hasPrefix("native") }) {
                            Text(nativeSummary(event.stateCode)).font(.caption)
                            Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2)
                        } else {
                            Text("No native delivery recorded this session.").font(.caption)
                        }
                        Text("Metadata check").font(.headline)
                        if let event = events.last(where: { $0.category == .request && $0.stateCode.hasPrefix("metadata") }) {
                            Text(metadataSummary(event.stateCode)).font(.caption)
                            Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2)
                        } else {
                            Text("No metadata check recorded this session.").font(.caption)
                        }
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
        .onAppear { reload() }
    }

    private func reload() {
        isLoading = true
        events = WatchAppAssembly.shared.diagnostics.snapshot()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let export = WatchDiagnosticsExporter.export(events: events, appVersion: version,
            generatedAt: Date(), salt: WatchDiagnosticsExporter.randomSalt())
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
        case "nativeAudioFileReceived": "Apple delivered audio; saving the inbox file."
        case "audioSavedAwaitingWorker": "Audio saved from Apple's inbox; installation worker has not started."
        case "chunkReceived": "Audio chunk reached the watch."
        case "audioFileReceived": "Audio installation worker started."
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

    private func nativeSummary(_ code: String) -> LocalizedStringKey {
        switch code {
        case "nativeAudioFileReceived": "Audio file callback received."
        case "nativeLiveMessageReceived": "Live message callback received."
        case "nativeContextReceived": "Device status callback received."
        case "nativeUserInfoReceived": "Background metadata callback received."
        default: "Apple connectivity session activated."
        }
    }

    private func metadataSummary(_ code: String) -> LocalizedStringKey {
        switch code {
        case "metadataCheckRequested": "Requested in the UI; waiting for the sync worker."
        case "metadataLocalReadStarted": "Sync worker started; reading the watch library."
        case "metadataLocalReadFinished": "Watch library read finished; preparing the request."
        case "metadataRequestQueued": "Request queued; checking live messaging."
        default: "Metadata check finished."
        }
    }
}
