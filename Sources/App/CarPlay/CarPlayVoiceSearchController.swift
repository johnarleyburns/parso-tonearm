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
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            audioEngine = engine
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let phrase = result?.bestTranscription.formattedString ?? ""
                let finished = result?.isFinal == true || error != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if finished {
                        await self.finish(phrase)
                    }
                }
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
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in continuation.resume(returning: allowed) }
        }
    }
}
#endif
