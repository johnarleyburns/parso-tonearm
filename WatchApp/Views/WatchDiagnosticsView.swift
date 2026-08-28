import SwiftUI
import TonearmWatchCore

/// §12 — the in-app diagnostics export. Renders the redacted, per-export-hashed JSON so a tester
/// can read it aloud or transcribe it. No titles, URLs, paths, credentials, tokens, or search
/// text can appear here — `WatchDiagnosticsExport` has nowhere to carry them.
struct WatchDiagnosticsView: View {
    @State private var json = "Loading…"
    @State private var eventCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("watch.diagnostics.refresh")

                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("watch.diagnostics.json")
                    .accessibilityValue("\(eventCount) events")
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Diagnostics")
        .task { await reload() }
    }

    private func reload() async {
        let export = await WatchAppAssembly.shared.diagnosticsExport()
        eventCount = export.eventCount
        if let data = try? WatchDiagnosticsExporter.encode(export) {
            json = String(decoding: data, as: UTF8.self)
        } else {
            json = "Encoding failed."
        }
    }
}
