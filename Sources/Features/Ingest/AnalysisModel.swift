import Foundation
import SwiftUI
import TonearmCore
import TonearmDJ

/// Observable progress for the Analysis screen (§41.3, mockup
/// `ipad/03-analysis.html`). Maps coordinator progress + the governor's
/// decision into view state, and holds the user's power/override preferences.
@MainActor
final class AnalysisModel: ObservableObject {

    @Published var progress: AnalysisProgress = AnalysisProgress(completed: 0, total: 0)
    @Published var isAnalyzing = false
    @Published var onlyWhileCharging = true
    @Published var userOverride = false
    @Published var errorMessage: String?

    /// Elapsed analysis time, for the honest ETA.
    @Published private(set) var elapsed: TimeInterval = 0

    private let coordinator: AnalysisCoordinator
    private var timer: Timer?
    private var startedAt: Date?

    init(coordinator: AnalysisCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Controls

    func startAnalysis() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        elapsed = 0
        startedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let startedAt = self?.startedAt else { return }
                self?.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        Task {
            // Refresh the pending queue and run.
            let _ = try? await coordinator.reconcileVersions()
            await coordinator.analyzeAll()
            isAnalyzing = false
            timer?.invalidate()
        }
    }

    func pause() {
        // The coordinator pauses analysis while a performance is live; pausing
        // here is expressed through the governor's gate.
        isAnalyzing = false
        timer?.invalidate()
    }

    // MARK: - Derived

    /// Honest ETA from completed fraction and elapsed time (§41.3).
    var etaText: String {
        guard let eta = progress.etaSeconds(elapsed: elapsed), eta.isFinite, eta > 0 else {
            return "—"
        }
        let m = Int(eta / 60)
        let s = Int(eta.truncatingRemainder(dividingBy: 60))
        return m > 0 ? "\(m)m \(s)s left" : "\(s)s left"
    }

    var fractionCompleted: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.completed) / Double(progress.total)
    }

    var governorWords: String { progress.governorWords }
}
