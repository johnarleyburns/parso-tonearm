import SwiftUI

/// The banner that replaces a lie (NFR-REL-2, §34A.5, plan 6.1).
///
/// When the graph stops, every readout on the performance surface becomes
/// false at once — the decks are not playing, the clock is not advancing, and
/// above all the recording is not recording. The app cannot fix that silently
/// and must not display it silently either, so this sits **above** the
/// performance surface, says what happened, says what became of the recording,
/// and offers the one action that can help.
///
/// It does not recover automatically. A set that restarts itself mid-transition
/// is worse than one that waits to be told, and the person who can judge that is
/// standing at the device.
struct EngineStoppedBanner: View {
    let reason: EngineLiveness.StopReason
    let recordingOutcome: String?
    let isRecovering: Bool
    let recover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.black)
                Text(reason.message)
                    .font(.headline)
                    .foregroundStyle(.black)
            }
            if let recordingOutcome {
                Text(recordingOutcome)
                    .font(.subheadline)
                    .foregroundStyle(.black.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: recover) {
                Text(isRecovering ? "Restarting…" : "Restart audio")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(isRecovering)
            .accessibilityIdentifier("dj.engine.recover")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // Amber, not red: the audio stopped, the app did not crash and the
        // recorded audio is not lost. Red would say "your set is gone".
        .background(Color(red: 0.98, green: 0.72, blue: 0.18), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dj.engine.stopped")
        .accessibilityLabel("Audio engine stopped. \(reason.message)")
    }
}

extension View {
    /// Overlay the banner on a performance surface when the graph has stopped.
    ///
    /// An overlay at the top rather than a sheet: a sheet would take the decks
    /// away, and the user may want to see the state of the set they just lost
    /// the engine under. Nothing beneath it is interactive-critical while the
    /// engine is down.
    @ViewBuilder
    func engineStoppedBanner(_ model: WorkspaceModel) -> some View {
        overlay(alignment: .top) {
            if let reason = model.engineStopped {
                EngineStoppedBanner(reason: reason,
                                    recordingOutcome: model.engineStopRecordingOutcome,
                                    isRecovering: model.isRecoveringEngine) {
                    Task { await model.recoverEngine() }
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.engineStopped)
    }
}
