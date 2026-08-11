import SwiftUI

/// Vibe Search (§41.4/41.5, mockups `ipad/04a-vibe-search-query.html`,
/// `ipad/04b-vibe-search-results.html`; collapsed to one scroll for the compact
/// class, §42.3/`iphone/02-vibe-search.html`). Free tier.
///
/// - Query state: privacy line once (NFR-PRIV-5), chips seeded from the library's
///   own descriptors, honest coverage footer (FR-SEM-8).
/// - Results state: per-row hybrid score decomposition (FR-SEM-2), +/− refine
///   chips (FR-SEM-4), latency footer, Play · Queue · Save as Smart Crate.
/// - A stated model-not-downloaded state with an ODR fetch (FR-SEM-6) — never a
///   silent empty list.
public struct VibeSearchView: View {
    @StateObject private var model: VibeSearchModel
    @State private var showTermPrompt = false
    @State private var termInput = ""
    @State private var showSavePrompt = false
    @State private var crateName = ""
    @State private var lastActionError: String?

    public init(model: VibeSearchModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                if !model.privacyAcknowledged { privacyCard }
                switch phase {
                case .query: queryState
                case .results: resultsState
                case .modelUnavailable: modelUnavailableState
                case .emptyQuery: emptyQueryState
                case .unindexedReference: unindexedReferenceState
                }
            }
            .padding(20)
        }
        .navigationTitle("Find by feel")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                freeBadge
            }
        }
        .task {
            await model.start()
        }
        .onChange(of: model.queryText) { _, newValue in
            model.updateQuery(newValue)
        }
        .alert("Add a word", isPresented: $showTermPrompt) {
            TextField("e.g. hypnotic", text: $termInput)
            Button("+ positive") { model.addPositiveTerm(termInput); termInput = "" }
            Button("− negative") { model.addNegativeTerm(termInput); termInput = "" }
            Button("Cancel", role: .cancel) { termInput = "" }
        }
        .alert("Name this Smart Crate", isPresented: $showSavePrompt) {
            TextField("e.g. Tunnel music", text: $crateName)
            Button("Save") { saveCrate() }
            Button("Cancel", role: .cancel) { crateName = "" }
        } message: {
            Text("A crate is the query, not a copy — it keeps finding new matches as your library grows.")
        }
        .alert("Couldn't save that", isPresented: .init(
            get: { lastActionError != nil },
            set: { if !$0 { lastActionError = nil } })) {
            Button("OK", role: .cancel) { lastActionError = nil }
        } message: {
            Text(lastActionError ?? "")
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Describe what you want to hear", text: $model.queryText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Describe what you want to hear")
    }

    // MARK: - Privacy (NFR-PRIV-5)

    private var privacyCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your query never leaves this device.")
                    .font(.system(size: 13, weight: .semibold))
                Text("The model that understands it runs on the Neural Engine, right here. There is no server to send it to, and we do not keep it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Got it") { model.acknowledgePrivacy() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.green.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Phases

    private enum Phase {
        case query
        case results
        case modelUnavailable
        case emptyQuery
        case unindexedReference
    }

    private var phase: Phase {
        guard let response = model.response else { return .query }
        switch response.state {
        case .textModelUnavailable: return .modelUnavailable
        case .emptyQuery: return .emptyQuery
        case .unindexedReference: return .unindexedReference
        case .ready: return .results
        }
    }

    // MARK: - Query state (mockup ipad/04a)

    private var queryState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try one of these — drawn from your own library, not a list we wrote")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(model.suggestionChips, id: \.self) { chip in
                    Button { model.updateQuery(chip) } label: {
                        Text(chip)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                alsoTryCard(
                    title: "More like this track",
                    body: "Hold any track and choose \"More like this\". Skips the text encoder entirely — results in about 20 ms.")
                alsoTryCard(
                    title: "Add and subtract",
                    body: "Refine a result set with + hypnotic and − vocals without starting over.")
                alsoTryCard(
                    title: "Save it as a Smart Crate",
                    body: "A crate is the query, not a copy. It keeps finding new matches as your library grows.")
            }

            coverageFooter
        }
    }

    private func alsoTryCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Also try")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Honest coverage, never an assumed-complete index (FR-SEM-8).
    private var coverageFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Index: \(model.coverage.indexed) of \(model.coverage.total) tracks · \(coveragePercent)% coverage · Tier A exact search")
                .font(.system(size: 12, design: .monospaced))
            Text("Missing tracks are still analyzing — results will improve.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coveragePercent: String {
        guard model.coverage.total > 0 else { return "—" }
        return String(format: "%.1f", Double(model.coverage.indexed) / Double(model.coverage.total) * 100)
    }

    // MARK: - Model not downloaded (FR-SEM-6)

    private var modelUnavailableState: some View {
        ContentUnavailableView {
            Label("Search model isn't downloaded", systemImage: "arrow.down.circle")
        } description: {
            Text("Vibe search needs the on-device language model, which arrives as a free download. Everything else works without it.")
        } actions: {
            Button("Download model") {
                Task { await model.fetchTextModel() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyQueryState: some View {
        Text("Describe a feeling, a texture, a memory of a room — not a title.")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unindexedReferenceState: some View {
        ContentUnavailableView {
            Label("This track isn't analyzed yet", systemImage: "waveform.badge.exclamationmark")
        } description: {
            Text("\"More like this\" needs the track's stored embedding. It will be available once analysis finishes.")
        }
    }

    // MARK: - Results state (mockup ipad/04b)

    private var resultsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            refineChips
            resultsList
            resultsFooter
            actionsRow
        }
    }

    /// +/− refinement chips re-rank without a fresh embed (FR-SEM-4).
    private var refineChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(model.positiveTerms, id: \.self) { term in
                    refineChip("+ \(term)", isAdditive: true) {
                        model.removePositiveTerm(term)
                    }
                }
                ForEach(model.negativeTerms, id: \.self) { term in
                    refineChip("− \(term)", isAdditive: false) {
                        model.removeNegativeTerm(term)
                    }
                }
                Button { showTermPrompt = true } label: {
                    Text("+ add a word…")
                        .font(.system(size: 12))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func refineChip(_ title: String, isAdditive: Bool,
                            onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(isAdditive ? Color.blue.opacity(0.12) : Color.orange.opacity(0.12),
                    in: Capsule())
    }

    private var resultsList: some View {
        let results = model.response?.results ?? []
        return VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                resultRow(result)
                if index < results.count - 1 {
                    Divider()
                }
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultRow(_ result: SearchResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.track.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(result.track.artistNames)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let bpm = result.track.bpm {
                        Text(String(format: "%.1f", bpm))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let key = result.track.camelot {
                        Text(key)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                scorePills(result)
            }
            Spacer()
            Text(String(format: "%.2f", result.finalScore))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .padding(12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("More like this") {
                Task { await model.searchSimilar(to: result.track.id) }
            }
        }
    }

    /// The hybrid score decomposed so ranking is legible, not magic (FR-SEM-2).
    private func scorePills(_ result: SearchResult) -> some View {
        HStack(spacing: 4) {
            scorePill("feel", result.reasons.semantic)
            scorePill("bpm", result.reasons.bpm)
            scorePill("key", result.reasons.key)
            scorePill("energy", result.reasons.energy)
        }
    }

    private func scorePill(_ label: String, _ value: Double) -> some View {
        Text("\(label) \(String(format: "%.2f", value))")
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.thickMaterial, in: Capsule())
    }

    private var resultsFooter: some View {
        HStack(spacing: 8) {
            Text("\(resultCount) results · scored against \(model.coverage.indexed) indexed tracks")
            Spacer()
            Text("\(latencyText)")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var resultCount: Int { model.response?.results.count ?? 0 }

    private var latencyText: String {
        guard let millis = model.response?.latencyMillis else { return "—" }
        return "\(Int(millis)) ms"
    }

    /// Play · Queue · Save as Smart Crate; "Load to deck" is present, labelled
    /// and locked (§40.4 rule 1).
    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button {
                model.onPlay?(model.response?.results ?? [])
            } label: {
                Label("Play all", systemImage: "play.fill")
            }
            Button {
                model.onQueue?(model.response?.results ?? [])
            } label: {
                Label("Queue", systemImage: "text.line.append")
            }
            Spacer()
            Button {
                crateName = ""
                showSavePrompt = true
            } label: {
                Label("Save as Smart Crate", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.bordered)
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                Text("Load to deck · Platterhead DJ")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private func saveCrate() {
        let name = crateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try model.saveAsSmartCrate(name: name)
            crateName = ""
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    // MARK: - Toolbar

    private var freeBadge: some View {
        Text("Free")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)
            .accessibilityLabel("Free feature")
    }
}
