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
    /// Offered only after a complete MSB/LSB pair was observed during capture.
    @Published public private(set) var capturedResolution: MidiBinding.Resolution = .sevenBit
    @Published public private(set) var statusMessage: String?
    /// The index into `setupSteps` while the guided walkthrough is running
    /// (plan dj-midi-alpha M4); nil when it is not.
    @Published public private(set) var setupStepIndex: Int?

    public let hardware: HardwareService
    private let store: ControllerProfileStore?
    private let syncID: String
    private var messageTask: Task<Void, Never>?
    private var learningAssembler = MidiValueAssembler()

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

    public var isRunningSetup: Bool { setupStepIndex != nil }

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
        // While the walkthrough owns the learn flow, a manual Learn tap is
        // ignored: the walkthrough's commit would otherwise advance a step the
        // user did not ask to move (plan M4).
        guard !isRunningSetup else { return }
        beginLearningInternal(action)
    }

    private func beginLearningInternal(_ action: EngineAction) {
        learningAction = action
        capturedAddress = nil
        capturedResolution = .sevenBit
        learningAssembler = MidiValueAssembler()
        statusMessage = isRunningSetup
            ? (currentSetupStep?.prompt ?? "Move the control you want for \(action.displayName).")
            : "Move the control you want for \(action.displayName)."
        hardware.beginLearning()
        listenForMessages()
    }

    public func cancelLearning() {
        learningAction = nil
        capturedAddress = nil
        capturedResolution = .sevenBit
        learningAssembler = MidiValueAssembler()
        statusMessage = nil
        hardware.endLearning()
    }

    /// Bind the captured control. Separate from capture on purpose: a knob
    /// sends a stream of values while it is moving, and binding the first one
    /// seen would make a nudge irreversible. The user sees what was captured
    /// and confirms.
    public func commitLearning() {
        guard let action = learningAction, let address = capturedAddress else { return }
        profile.learn(action, at: address, transform: action.defaultTransform,
                      resolution: capturedResolution)
        statusMessage = "\(action.displayName) is now \(bindingDescription(for: action))."
        learningAction = nil
        capturedAddress = nil
        hardware.endLearning()
        persist()
        if isRunningSetup { advanceSetup() }
    }

    public func clearBinding(_ action: EngineAction) {
        profile.bindings.removeAll { $0.action == action }
        persist()
    }

    // MARK: - The guided learn walkthrough (plan dj-midi-alpha M4)

    /// One step of the "Set up my controller" walkthrough: the action being
    /// taught, and what the control does **in DJ words** — never `EngineAction`
    /// words, which assume the user already knows the app.
    public struct MidiSetupStep: Sendable, Equatable, Identifiable {
        public let action: EngineAction
        public let prompt: String
        public var id: EngineAction { action }

        public init(action: EngineAction, prompt: String) {
            self.action = action
            self.prompt = prompt
        }
    }

    /// The essential set in performance order (plan M4): crossfader → channel
    /// faders → transport → cue → EQ → filter → tempo → jog → record. Exitable
    /// at any point with a usable partial mapping.
    public static let setupSteps: [MidiSetupStep] = [
        .init(action: .crossfader,
              prompt: "The crossfader — sweep it fully to one side and back."),
        .init(action: .channelFader(deck: .a),
              prompt: "Deck A's channel fader — lower it and back."),
        .init(action: .channelFader(deck: .b),
              prompt: "Deck B's channel fader — lower it and back."),
        .init(action: .play(deck: .a),
              prompt: "Deck A's play/pause button."),
        .init(action: .play(deck: .b),
              prompt: "Deck B's play/pause button."),
        .init(action: .cue(deck: .a),
              prompt: "Deck A's cue button — the one that jumps back to the cue point."),
        .init(action: .cue(deck: .b),
              prompt: "Deck B's cue button."),
        .init(action: .headphoneCue(deck: .a),
              prompt: "Deck A's headphone cue — the pre-listen button."),
        .init(action: .headphoneCue(deck: .b),
              prompt: "Deck B's headphone cue."),
        .init(action: .eq(deck: .a, band: .low),
              prompt: "Deck A's low EQ knob."),
        .init(action: .eq(deck: .a, band: .mid),
              prompt: "Deck A's mid EQ knob."),
        .init(action: .eq(deck: .a, band: .high),
              prompt: "Deck A's high EQ knob."),
        .init(action: .eq(deck: .b, band: .low),
              prompt: "Deck B's low EQ knob."),
        .init(action: .eq(deck: .b, band: .mid),
              prompt: "Deck B's mid EQ knob."),
        .init(action: .eq(deck: .b, band: .high),
              prompt: "Deck B's high EQ knob."),
        .init(action: .filter(deck: .a),
              prompt: "Deck A's sweep filter."),
        .init(action: .filter(deck: .b),
              prompt: "Deck B's sweep filter."),
        .init(action: .tempo(deck: .a),
              prompt: "Deck A's tempo fader."),
        .init(action: .tempo(deck: .b),
              prompt: "Deck B's tempo fader."),
        .init(action: .jog(deck: .a),
              prompt: "Deck A's jog wheel — turn it a few notches."),
        .init(action: .jogTouch(deck: .a),
              prompt: "Deck A's jog touch — touch the platter and let go."),
        .init(action: .jog(deck: .b),
              prompt: "Deck B's jog wheel — turn it a few notches."),
        .init(action: .jogTouch(deck: .b),
              prompt: "Deck B's jog touch — touch the platter and let go."),
        .init(action: .record,
              prompt: "The record button — tap it once."),
    ]

    /// The step the walkthrough is currently on, or nil when it is not running.
    public var currentSetupStep: MidiSetupStep? {
        guard let index = setupStepIndex, Self.setupSteps.indices.contains(index) else { return nil }
        return Self.setupSteps[index]
    }

    /// "3 of 24", shown as the walkthrough advances.
    public var setupProgressText: String? {
        guard let index = setupStepIndex else { return nil }
        return "\(index + 1) of \(Self.setupSteps.count)"
    }

    /// Begin the guided walkthrough at the first step.
    public func startSetup() {
        guard !isRunningSetup else { return }
        setupStepIndex = 0
        statusMessage = nil
        beginLearningInternal(Self.setupSteps[0].action)
    }

    /// Skip the current step without binding it; the earlier bindings stay.
    public func skipSetupStep() {
        guard isRunningSetup else { return }
        cancelLearning()
        advanceSetup()
    }

    /// Stop the walkthrough, keeping whatever has been mapped so far.
    public func endSetup() {
        guard isRunningSetup else { return }
        setupStepIndex = nil
        cancelLearning()
        if profile.bindings.isEmpty {
            statusMessage = nil
        } else {
            statusMessage = "Setup stopped — \(profile.bindings.count) controls mapped so far."
        }
    }

    private func advanceSetup() {
        guard let index = setupStepIndex else { return }
        let next = index + 1
        if next < Self.setupSteps.count {
            setupStepIndex = next
            beginLearningInternal(Self.setupSteps[next].action)
        } else {
            setupStepIndex = nil
            statusMessage = "Setup complete — \(profile.bindings.count) controls mapped."
        }
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
                let now = DispatchTime.now().uptimeNanoseconds
                if let pairAddress = self.learningAssembler.observePair(message, at: now) {
                    self.capturedAddress = pairAddress
                    self.capturedResolution = .fourteenBit
                } else if self.capturedResolution == .sevenBit {
                    self.capturedAddress = message.address
                }
            }
        }
    }

    public func setCapturedResolution(_ resolution: MidiBinding.Resolution) {
        guard capturedResolution == .fourteenBit || resolution == .sevenBit else { return }
        capturedResolution = resolution
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
