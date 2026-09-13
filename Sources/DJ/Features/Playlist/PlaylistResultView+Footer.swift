import SwiftUI

// MARK: - Footer and FR-PLIST-10 blend card (dismissible, inert in M3)

extension PlaylistResultView {
    var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(footerLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isShortPool {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Could only fill \(model.rows.count) of \(model.requestedCount) tracks — nothing was padded in that doesn't fit the brief.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }

            if sizeClass == .compact {
                HStack(spacing: 8) {
                    Button {
                        playlistTitle = model.resultTitle
                        showSavePlaylistPrompt = true
                    } label: {
                        Label("Save", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.onPlay?(model.rows)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button { Task { await model.extend(minutes: 30) } } label: {
                        Label("Extend +30 min", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await model.reshuffle(from: 1, to: max(0, model.rows.count - 2)) } } label: {
                        Label("Reshuffle the middle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    var footerLine: String {
        var parts = ["\(model.rows.count) tracks",
                     "\(AutoPlaylistModel.durationText(Double(model.totalSeconds))) of \(model.targetSummaryText)"]
        if let delta = model.durationDeltaPercent {
            parts.append(String(format: "(%+.1f%%)", delta))
        }
        if let cost = model.meanTransitionCost {
            parts.append(String(format: "mean transition cost %.2f", cost))
        }
        if let smoother = model.smootherThanShuffleText {
            parts.append(smoother)
        }
        if model.rejectionCount > 0 {
            parts.append("\(model.rejectionCount) rejected and remembered")
        }
        return parts.joined(separator: " · ")
    }

    var blendCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 20))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Want these to actually blend into each other?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Platterhead DJ turns this playlist into a gig crate: two decks, beatmatched transitions at the points already scored above. One-time purchase — coming in 3.0.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Coming in 3.0") { showBlendAlert = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Not now") { model.dismissBlendCard() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.indigo.opacity(0.4), lineWidth: 1))
    }

    func savePlaylist() {
        let title = playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task { await model.saveAsPlaylist(title: title) }
    }
}
