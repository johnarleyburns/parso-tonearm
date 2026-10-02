#if !targetEnvironment(macCatalyst)
import AVFoundation
import CarPlay
import Speech
import TonearmCore
import UIKit

/// Hands-free library search for the iOS 27 CarPlay surface. The system
/// provides the voice-control presentation; Speech supplies the live partial
/// transcript and hands the final query back to the same FTS-backed search
/// path used by the keyboard search template.
@MainActor
final class CarPlayVoiceSearchController: NSObject {
    private enum State { case listening, searching, unavailable }

    private let interfaceController: CPInterfaceController
    private weak var search: CarPlaySearchController?
    private var template: CPVoiceControlTemplate?
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: .current)

    init(interfaceController: CPInterfaceController, search: CarPlaySearchController) {
        self.interfaceController = interfaceController
        self.search = search
        super.init()
    }

    func present() {
        guard CarPlaySearchAvailability.templateSupported else { return }
        stopListening()
        let states = [
            CPVoiceControlState(identifier: "listening", titleVariants: ["Say a song, artist, or album"], image: UIImage(systemName: "waveform"), repeats: true),
            CPVoiceControlState(identifier: "searching", titleVariants: ["Searching your library…"], image: UIImage(systemName: "magnifyingglass"), repeats: true),
            CPVoiceControlState(identifier: "unavailable", titleVariants: ["Voice search unavailable"], image: UIImage(systemName: "mic.slash"), repeats: false)
        ]
        let voice = CPVoiceControlTemplate(voiceControlStates: states)
        template = voice
        Task { @MainActor in
            do {
                _ = try await interfaceController.pushTemplate(voice, animated: true)
                await beginListening()
            } catch {
                stopListening()
            }
        }
    }

    private func beginListening() async {
        guard await requestAuthorization() else { return showUnavailable() }
        guard let recognizer, recognizer.isAvailable else { return showUnavailable() }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            Self.installTap(on: engine.inputNode, feeding: request)
            audioEngine = engine
            recognitionTask = Self.startRecognition(recognizer, request: request) { [weak self] phrase in
                Task { @MainActor [weak self] in await self?.finish(phrase) }
            }
            try engine.start()
        } catch {
            showUnavailable()
        }
    }

    private func finish(_ phrase: String) async {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showUnavailable()
            return
        }
        template?.activateVoiceControlState(withIdentifier: "searching")
        stopListening()
        await search?.presentVoiceResults(for: phrase, interfaceController: interfaceController)
    }

    private func showUnavailable() {
        template?.activateVoiceControlState(withIdentifier: "unavailable")
        stopListening()
    }

    private func stopListening() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestAuthorization() async -> Bool {
        guard await Self.speechAuthorized() else { return false }
        return await Self.recordPermissionGranted()
    }

    // TCC calls these completion handlers on its own queue. Written inside this @MainActor class
    // they inherited main-actor isolation, and Swift 6's runtime check trapped (TestFlight 513:
    // EXC_BREAKPOINT in requestAuthorization's closure). Non-isolated, with @Sendable handlers,
    // they only resume the continuation — safe from any queue.
    /// The tap runs on the real-time audio thread; it must not inherit this class's main-actor
    /// isolation (Swift 6 traps on that), so it's built here.
    private nonisolated static func installTap(on input: AVAudioInputNode,
                                               feeding request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
            request.append(buffer)
        }
    }

    /// Speech calls the result handler on its own queue; only the final phrase hops to the main
    /// actor through `onFinal`.
    private nonisolated static func startRecognition(
        _ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        onFinal: @escaping @Sendable (String) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { @Sendable result, error in
            guard result?.isFinal == true || error != nil else { return }
            onFinal(result?.bestTranscription.formattedString ?? "")
        }
    }

    private nonisolated static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private nonisolated static func recordPermissionGranted() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { @Sendable allowed in
                continuation.resume(returning: allowed)
            }
        }
    }
}
#endif
