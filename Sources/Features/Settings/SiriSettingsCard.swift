#if os(iOS)
import Intents
import SwiftUI

/// Settings › Playback: "Siri & CarPlay". The user-initiated switch for
/// SiriKit media requests. Authorization is requested only from this button
/// (CLAUDE.md: no silent/magic background work), the current status is
/// always shown, and turning it off is pointed at the only place iOS allows
/// that.
///
/// While authorized: "Play <song> on Platterhead" works in one sentence, and
/// CarPlay shows the "Ask Siri" cell at the top of each tab
/// (`CarPlayRootBuilder`). The App Shortcuts ("Play a song in
/// Platterhead") work either way.
struct SiriSettingsCard: View {
    @State private var status = SiriAuthorization.status
    @State private var requesting = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Siri & CarPlay").font(.system(size: 13.5))
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            if status == .notDetermined {
                Button(requesting ? "Asking…" : "Allow Siri") {
                    requesting = true
                    Task {
                        status = await SiriAuthorization.request()
                        requesting = false
                    }
                }
                .disabled(requesting)
                .buttonStyle(.bordered)
                .tint(Palette.brassDeep)
                .accessibilityIdentifier("settings.siri.allow")
            } else {
                Text(status == .authorized ? "On" : "Off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status == .authorized ? Palette.ink : Palette.ink3)
                    .accessibilityIdentifier("settings.siri.status")
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .onAppear { status = SiriAuthorization.status }
    }

    private var detail: String {
        switch status {
        case .authorized:
            return "“Play <song> on Platterhead” works hands-free, and CarPlay shows Ask Siri. Turn off in iOS Settings › Apps › Platterhead › Siri."
        case .denied:
            return "Off. Turn on in iOS Settings › Apps › Platterhead › Siri to ask for songs by name in the car."
        case .restricted:
            return "Siri is restricted on this iPhone."
        case .notDetermined:
            return "Ask Siri for any song, artist or playlist by name, including in CarPlay."
        @unknown default:
            return "Siri status unavailable."
        }
    }
}
#endif
