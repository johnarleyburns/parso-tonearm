import Combine
import Foundation

/// The MIDI settings screen's model (§44.4, FR-HW-1/2, plan 6.5).
///
/// Holds the learn state machine and the working profile; the CoreMIDI side is
/// `HardwareService` and the meaning side is `MidiMapping`/`MidiRouter`, so
/// this is only the choreography between them — and it is testable, because the
/// messages arrive through `HardwareService.receive`, which a test can call.
@MainActor
public final class MidiSettingsModel: ObservableObject {

    @Published public private(set) var profile: ControllerProfile
    /// The action the user is currently binding, if any.
    @Published public private(set) var learningAction: EngineAction?
    /// The last message seen while learning — shown so the user can confirm it
    /// is the control they meant before it is bound.
    @Published public private(set) var capturedAddress: MidiAddress?
    @Published public private(set) var statusMessage: String?

    public let hardware: HardwareService
    private let store: ControllerProfileStore?
    private let syncID: String
    private var messageTask: Task<Void, Never>?

    public init(hardware: HardwareService = HardwareService(),
                store: ControllerProfileStore? = nil,
                syncID: String = "default",
                profile: ControllerProfile = ControllerProfile(name: "My controller")) {
        self.hardware = hardware
        self.store = store
        self.syncID = syncID
        self.profile = profile
    }

    /// A store-backed model for the shipping app (plan dj-midi-alpha M1): the
    /// active profile is loaded at construction so the screen shows what the
    /// user already taught it rather than an empty table, and every learn /
    /// clear / import writes through to the DJ database — a mapping learned
    /// here is still there next week, and after a force-quit.
    public static func live(hardware: HardwareService = HardwareService(),
                            store: ControllerProfileStore = ControllerProfileStore(pool: DJLibraryStore.shared.pool),
                            syncID: String = "default") -> MidiSettingsModel {
        let profile = (try? store.activeProfile()) ?? ControllerProfile(name: "My controller")
        return MidiSettingsModel(hardware: hardware, store: store, syncID: syncID, profile: profile)
    }

    public var bindableActions: [EngineAction] { EngineAction.bindableActions }

    public func binding(for action: EngineAction) -> MidiBinding? {
        profile.bindings.first { $0.action == action }
    }

    /// A one-line description of what is bound to an action, for the list.
    public func bindingDescription(for action: EngineAction) -> String {
        guard let binding = binding(for: action) else { return "Not mapped" }
        switch binding.address.type {
        case .cc: return "CC \(binding.address.number) · ch \(binding.address.channel)"
        case .note: return "Note \(binding.address.number) · ch \(binding.address.channel)"
        case .pitchBend: return "Pitch bend · ch \(binding.address.channel)"
        }
    }

    // MARK: - Learn (§44.4)

    /// Start listening for the next control the user moves.
    public func beginLearning(_ action: EngineAction) {
        learningAction = action
        capturedAddress = nil
        statusMessage = "Move the control you want for \(action.displayName)."
        hardware.beginLearning()
        listenForMessages()
    }

    public func cancelLearning() {
        learningAction = nil
        capturedAddress = nil
        statusMessage = nil
        hardware.endLearning()
    }

    /// Bind the captured control. Separate from capture on purpose: a knob
    /// sends a stream of values while it is moving, and binding the first one
    /// seen would make a nudge irreversible. The user sees what was captured
    /// and confirms.
    public func commitLearning() {
        guard let action = learningAction, let address = capturedAddress else { return }
        profile.learn(action, at: address, transform: action.defaultTransform)
        statusMessage = "\(action.displayName) is now \(bindingDescription(for: action))."
        learningAction = nil
        capturedAddress = nil
        hardware.endLearning()
        persist()
    }

    public func clearBinding(_ action: EngineAction) {
        profile.bindings.removeAll { $0.action == action }
        persist()
    }

    private func listenForMessages() {
        guard messageTask == nil else { return }
        messageTask = Task { [weak self] in
            guard let self else { return }
            for await message in self.hardware.messages {
                guard self.learningAction != nil else { continue }
                // A release (value 0) is not the control being moved — binding
                // to it would capture the note-off of the previous tap.
                guard message.value > 0 else { continue }
                self.capturedAddress = message.address
            }
        }
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(profile, syncID: syncID)
        } catch {
            // A mapping the user believes is saved and is not would come back
            // as "my controller forgot everything", so say it now.
            statusMessage = "The mapping could not be saved (\(error))."
        }
    }

    // MARK: - Interchange (FR-HW-2)

    public func exportData() throws -> Data {
        try ControllerProfileStore.exportData(profile)
    }

    public func importProfile(from data: Data) {
        do {
            profile = try ControllerProfileStore.importProfile(from: data)
            statusMessage = "Imported \(profile.bindings.count) mappings from \(profile.name)."
            persist()
        } catch {
            statusMessage = "That file is not a Platterhead controller mapping."
        }
    }

    deinit { messageTask?.cancel() }
}
