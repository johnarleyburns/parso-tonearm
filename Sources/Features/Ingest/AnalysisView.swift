import SwiftUI
import TonearmCore
import TonearmDJ

/// Analysis & library health screen (§41.3, mockup `ipad/03-analysis.html`):
/// per-stage progress with honest ETAs, the governor's current decision in
/// words, and the controls (Analyze now · Only while charging · Re-analyze).
struct AnalysisView: View {
    @ObservedObject var model: AnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progressCard.padding(.top, 18)
            governorCard.padding(.top, 14)
            controlsCard.padding(.top, 14)
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.system(size: 12.5)).foregroundStyle(Palette.danger)
                    .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Palette.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Library Health").font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.ink)
            Text("Analysis runs in the background, paused for performances and heat.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Analysis").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(model.progress.completed) / \(model.progress.total) tracks")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink2)
            }
            ProgressView(value: model.fractionCompleted)
                .tint(Palette.brass)
            HStack {
                if let current = model.progress.currentTrackTitle {
                    Text("Analyzing “\(current)”…").font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                } else {
                    Text(model.isAnalyzing ? "Starting…" : "Idle").font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                }
                Spacer()
                Text("ETA \(model.etaText)").font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(16)
        .background(Color(hex: 0x1E2026))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var governorCard: some View {
        HStack(spacing: 10) {
            Circle().fill(model.isAnalyzing ? Color.green : Palette.brass)
                .frame(width: 8, height: 8)
            Text(model.governorWords.isEmpty ? "Awaiting analysis…" : model.governorWords)
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                .lineLimit(2)
            Spacer()
        }
        .padding(14)
        .background(Color(hex: 0x1E2026))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.onlyWhileCharging) {
                Text("Only while charging").font(.system(size: 13)).foregroundStyle(Palette.ink)
            }
            .tint(Palette.brass)
            Toggle(isOn: $model.userOverride) {
                Text("Allow on battery (explicit)").font(.system(size: 13)).foregroundStyle(Palette.ink)
            }
            .tint(Palette.brass)

            HStack(spacing: 10) {
                Button {
                    model.startAnalysis()
                } label: {
                    Text(model.isAnalyzing ? "Analyzing…" : "Analyze now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x221503))
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(model.isAnalyzing ? Color.gray.opacity(0.3) : Palette.brass)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(model.isAnalyzing)

                Button {
                    model.pause()
                } label: {
                    Text("Pause")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 96, height: 42)
                        .background(Color(hex: 0x1E2026))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(Color(hex: 0x1E2026))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
