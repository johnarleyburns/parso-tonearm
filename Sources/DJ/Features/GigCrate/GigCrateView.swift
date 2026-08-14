import SwiftUI

/// The gig crate surface (mockup `ipad/14`, §41.17): a promoted playlist with
/// per-track readiness, the storage this crate consumes against the §43.6
/// budget, and the eviction preview shown **before** any eviction happens
/// (FR-ANL-9, AT-STEM-\*). The bridge between free and Pro — FR-PLIST-9.
public struct GigCrateView: View {
    @ObservedObject public var model: GigCrateModel
    /// Presented when the user picks a playlist to promote.
    @State private var showingPromote = false
    /// The "Open in workspace" hook the presenter wires (5.10+ owns the seam).
    public var onOpenInWorkspace: ((Int64) -> Void)?
    /// The "Load to deck" hook per crate track.
    public var onLoadToDeck: ((Int64) -> Void)?

    public init(model: GigCrateModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                statGrid
                if let detail = model.detail {
                    governorPanel
                    trackTable(detail)
                    lowerRow(detail)
                }
            }
            .padding(13)
        }
        .background(Color.black.ignoresSafeArea())
        .task { await model.refresh() }
        .sheet(isPresented: $showingPromote) { promoteSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Pill("PRO", color: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.detail?.crate.name ?? "Gig Crates")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let words = statusWords {
                Text(words)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.18), in: Capsule())
                    .foregroundStyle(.green)
            }
            Button("Promote a playlist") { showingPromote = true }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
            Button("Prepare") {
                Task { await model.prepare() }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .disabled(model.isPreparing)
        }
    }

    private var subtitle: String {
        guard let detail = model.detail else { return "Promote a playlist to performance readiness" }
        let duration = detail.tracks.reduce(TimeInterval(0)) { $0 + ($1.durationSec ?? 0) }
        var parts: [String] = []
        if !detail.playlistTitle.isEmpty {
            parts.append("From “\(detail.playlistTitle)”")
        }
        parts.append("\(detail.trackCount) tracks")
        if duration > 0 {
            let m = Int(duration / 60)
            parts.append("\(m / 60):\(String(format: "%02d", m % 60)):00")
        }
        return parts.joined(separator: " · ")
    }

    private var statusWords: String? {
        if model.isPreparing { return "Preparing" }
        if model.isReady { return "Ready" }
        return nil
    }

    // MARK: - The four stat cards (mockup's header grid)

    private var statGrid: some View {
        let d = model.detail
        let trackCount = d?.trackCount ?? 0
        let cached = d?.cachedCount ?? 0
        let analyzed = d?.analyzedCount ?? 0
        let stems = d?.stemsReadyCount ?? 0
        return HStack(spacing: 9) {
            StatCard(kicker: "Audio cached",
                     value: "\(cached)/\(trackCount)",
                     fraction: trackCount == 0 ? 0 : Double(cached) / Double(trackCount),
                     accent: .green)
            StatCard(kicker: "Analyzed",
                     value: "\(analyzed)/\(trackCount)",
                     fraction: trackCount == 0 ? 0 : Double(analyzed) / Double(trackCount),
                     accent: .green)
            StatCard(kicker: "Stems separated",
                     value: "\(stems)/\(trackCount)",
                     fraction: d?.stemsFraction ?? 0,
                     accent: model.isPreparing ? .orange : .green)
            StatCard(kicker: "Storage for this crate",
                     value: StorageBudgetService.bytesText(d?.projectedStemBytes ?? 0),
                     fraction: budgetFraction,
                     accent: .cyan)
        }
    }

    /// The crate's projected stem bytes against the free budget headroom.
    private var budgetFraction: Double {
        guard let plan = model.evictionPreview, plan.budget > 0 else { return 0 }
        let projected = Double(model.detail?.projectedStemBytes ?? 0)
        return min(1, projected / Double(plan.budget))
    }

    // MARK: - Governor panel

    private var governorPanel: some View {
        let words = model.governorWords
        return HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isPreparing ? "Preparing now." : "Stems not started.")
                    .font(.system(size: 13, weight: .semibold))
                Text(words.isEmpty
                        ? "Separation runs at full concurrency while charging at Nominal — at Serious it stops and waits. Nothing here needs the network."
                        : words)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isPreparing {
                ProgressView().controlSize(.small)
            } else {
                Button("Prepare") { Task { await model.prepare() } }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Track table

    private func trackTable(_ detail: GigCrateDetail) -> some View {
        VStack(spacing: 0) {
            tableHeader
            ForEach(detail.tracks) { row in
                trackRow(row)
                if row.id != detail.tracks.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: 24, alignment: .leading)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("BPM").frame(width: 52, alignment: .trailing)
            Text("Key").frame(width: 40, alignment: .trailing)
            Text("Stems").frame(width: 92, alignment: .leading)
            Text("Audio").frame(width: 74, alignment: .leading)
            Text("Size").frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func trackRow(_ row: GigCrateTrackRow) -> some View {
        HStack(spacing: 8) {
            Text("\(row.position)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(row.artistNames).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.bpm.map { String(format: "%.1f", $0) } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
            Text(row.camelot ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            stemsPill(row).frame(width: 92, alignment: .leading)
            audioPill(row).frame(width: 74, alignment: .leading)
            Text(StorageBudgetService.bytesText(row.stemsBytes))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func stemsPill(_ row: GigCrateTrackRow) -> some View {
        switch row.stems {
        case .ready:
            return Pill("Ready", color: .green)
        case .running:
            return Pill("Separating", color: .orange)
        case .failed:
            return Pill("Failed", color: .red)
        case .evicted:
            return Pill("Evicted", color: .yellow)
        case .pending:
            return Pill("Queued", color: .gray)
        }
    }

    private func audioPill(_ row: GigCrateTrackRow) -> some View {
        if row.audioCached {
            return Pill("Local", color: .green)
        }
        return Pill("Caching", color: .cyan)
    }

    // MARK: - Lower row (FR-LIB-8 notice + "Making room")

    private func lowerRow(_ detail: GigCrateDetail) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if detail.cachedCount < detail.trackCount {
                fr8Notice(detail)
            }
            makingRoomCard
        }
    }

    /// FR-LIB-8 in the flesh: a partially-cached remote track is honestly
    /// deck-disabled — the render path never waits on a network (§4.1).
    private func fr8Notice(_ detail: GigCrateDetail) -> some View {
        let firstNotCached = detail.tracks.first { !$0.audioCached }
        return VStack(alignment: .leading, spacing: 4) {
            Text("One track can't go on a deck yet.")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.yellow)
            Text(firstNotCached.map { "\($0.title) is still downloading. A deck never waits on a network, so the slot stays disabled until every byte is here." }
                    ?? "Some tracks are still downloading.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var makingRoomCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Making room")
                .font(.system(size: 13, weight: .bold))
            if let plan = model.evictionPreview {
                if plan.needsEviction {
                    Text(plan.fits
                            ? "This crate needs room. These stems would be dropped (oldest performance first):"
                            : "This crate can't fit even after eviction — trim it or raise the budget.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(plan.evictions, id: \.crateID) { usage in
                        evictionRow(usage)
                    }
                } else {
                    Text("This crate fits inside your \(StorageBudgetService.bytesText(plan.budget)) stem budget. Nothing will be evicted.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func evictionRow(_ usage: StorageBudgetService.CrateUsage) -> some View {
        HStack {
            Text(usage.name).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Text(StorageBudgetService.bytesText(usage.stemsBytes))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Promote sheet

    private var promoteSheet: some View {
        NavigationStack {
            List(model.availablePlaylists, id: \.id) { playlist in
                Button {
                    showingPromote = false
                    Task {
                        await model.promote(playlistID: playlist.id ?? 0, name: playlist.title)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.title).font(.system(size: 14, weight: .semibold))
                        Text("Promote to a gig crate")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Promote a playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPromote = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Small components

private struct StatCard: View {
    let kicker: String
    let value: String
    let fraction: Double
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kicker)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(accent)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
