import Foundation
import Combine
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import SwiftUI
import TonearmCore
import TonearmDiscovery

@MainActor
final class DJPerformanceModel: ObservableObject {
    @Published var deckA = DJDeckState(id: .a)
    @Published var deckB = DJDeckState(id: .b)
    @Published var outputMode: DJOutputMode = .stereo
    @Published var cueA = false
    @Published var cueB = false
    @Published var bassFader = 0.5
    @Published var crossfader = 0.5
    @Published var activeDeck: DJDeckID = .a
    @Published var masterDeck: DJDeckID?
    @Published var headphoneLevel = 0.7
    @Published var cueMasterMix = 0.5
    @Published var isolatorLow = 0.5
    @Published var isolatorMid = 0.5
    @Published var isolatorHigh = 0.5
    @Published var beatFXDepth = 0.5
    @Published var beatFXOn = false
    @Published var beatFXAssignment = "A"
    @Published var beatFXKind = 1
    @Published var beatFXBeatIndex = 3
    @Published var autoGain = true
    @Published var recording = false
    @Published var recordingStartedAt: Date?
    @Published var masterLevel = UserDefaults.standard.object(forKey: "dj.masterLevel") as? Double ?? 0.8
    @Published var loadError: String?
    @Published var loadErrors: [DJDeckID: String] = [:]
    @Published var loadingDecks: Set<DJDeckID> = []
    @Published var loadPhases: [DJDeckID: DJLoadPhase] = [:]

    let store: LibraryStore
    var loadGeneration: [DJDeckID: Int] = [.a: 0, .b: 0]
    var tickTask: Task<Void, Never>?
    var glideTasks: [DJDeckID: Task<Void, Never>] = [:]
    var audio = DJAudioBacker()
    var scratching: Set<DJDeckID> = []
    var tapTimes: [DJDeckID: [Date]] = [:]
    var deckCancellables = Set<AnyCancellable>()
    var lastStorageCheck = Date.distantPast

    init(store: LibraryStore = .shared) {
        self.store = store
        deckA.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &deckCancellables)
        deckB.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &deckCancellables)
        audio.setBassBlend(0.5)
        audio.setCrossfader(0.5)
        audio.setMasterLevel(masterLevel)
        audio.setChannelLevel(deck: .a, value: deckA.channelLevel)
        audio.setChannelLevel(deck: .b, value: deckB.channelLevel)
        if #available(iOS 17.0, macOS 14.0, *) {
            CloudSyncEngine.shared.onDJTrackPrepApplied = { [weak self] trackID in
                self?.refreshPrepIfLoaded(trackID: trackID)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = await MainActor.run { [weak self] in
                    self?.deckA.isPlaying == true || self?.deckB.isPlaying == true || self?.scratching.isEmpty == false
                }
                // PAE's event stream is polled on the main/display actor, but
                // 60 Hz ObservableObject writes make the whole DJ surface
                // participate in every audio tick. Thirty FPS is enough for a
                // centered playhead and keeps Canvas/layout work bounded.
                try? await Task.sleep(for: .milliseconds(active ? 16 : 100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    deinit {
        tickTask?.cancel()
        glideTasks.values.forEach { $0.cancel() }
    }
}
