import Foundation

/// The AT-HW-06 regression hook (plan dj-midi-alpha M1): injects a bound CC
/// through `HardwareService.receive` — a real seam, not a mock — shortly after
/// the workspace attaches a controller, so the UI lane can assert that a mapped
/// control reaches the engine without a physical device (§53.4's "drive the
/// seam, never fake the hardware").
///
/// Armed only under `-uiRegression` **and** `-midiInjectCC`. A build without
/// the hook is simply an app that never injects; the lane's assertion is on
/// the crossfader's published value, so a broken wiring fails the lane rather
/// than being papered over.
@MainActor
public enum MidiInjectionHook {

    /// The message the lane's seeded profile binds to the crossfader: CC 7,
    /// channel 1, sent at full travel so a bipolar transform lands the
    /// crossfader at 1.0.
    public static let injectedMessage = MidiMessage(
        address: MidiAddress(type: .cc, channel: 1, number: 7), value: 127)

    private static var task: Task<Void, Never>?

    /// Register the workspace-attached controller. When the injection flags are
    /// present, schedules one injected message once the workspace has had a
    /// moment to attach the profile and open its message task.
    public static func register(_ hardware: HardwareService) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiRegression"), arguments.contains("-midiInjectCC") else { return }
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            hardware.receive(injectedMessage)
        }
    }
}
