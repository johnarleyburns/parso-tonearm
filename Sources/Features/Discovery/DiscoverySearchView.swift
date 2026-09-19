// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../../LICENSE.

#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import TonearmCore
import TonearmDiscovery

/// The Library sound-search screen (plan §10.1, C07). Reachable from the
/// ordinary Library screen and from Now Playing → "More like this"; never
/// requires the DJ tab or a paywall.
///
/// All state/scoring/validation lives in the portable, unit-tested
/// `DiscoverySearchViewModel` / `DiscoverySearchPresentation`. This view is
/// declarative rendering only — no model or DB work in `body`.
struct DiscoverySearchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var model: DiscoverySearchViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    DiscoverySearchContent(model: model)
                } else {
                    ProgressView("Preparing search…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Find Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if model == nil {
                model = await DiscoveryRuntimeController.shared.searchViewModel(
                    appState: appState, player: player)
            }
        }
    }
}

private struct DiscoverySearchContent: View {
    @ObservedObject var model: DiscoverySearchViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @State private var refinementDraft: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modePicker
                searchField
                scopePicker
                musicalFilters
                refinements
                Divider()
                resultsSection
            }
            .padding(16)
        }
        .foregroundStyle(Palette.ink)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Inputs

    private var modePicker: some View {
        Picker("Search mode", selection: $model.inputMode) {
            Text("Metadata").tag(DiscoverySearchInputMode.metadata)
            Text("Find by sound").tag(DiscoverySearchInputMode.findBySound)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Search mode")
        .accessibilityHint("Metadata searches titles and artists. Find by sound matches how music sounds.")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: model.referenceTrackID == nil ? "magnifyingglass" : "wand.and.stars")
                .foregroundStyle(Palette.ink3)
            if model.referenceTrackID == nil {
                TextField(
                    model.inputMode == .findBySound
                        ? "Describe a sound, e.g. warm analog pads"
                        : "Search titles and artists",
                    text: $model.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search text")
            } else {
                Text("Finding tracks that sound similar")
                    .foregroundStyle(Palette.ink2)
                Spacer()
                Button("Clear") { model.exitSimilarMode() }
                    .font(.footnote)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassSurface(cornerRadius: 20)
    }

    private var scopePicker: some View {
        Menu {
            Button {
                model.scope = .allMusic
            } label: {
                Label("All music", systemImage: model.scope == .allMusic ? "checkmark" : "")
            }
            ForEach(appState.sources.compactMap { s -> (Int64, String)? in
                guard let id = s.id else { return nil }
                return (id, s.title)
            }, id: \.0) { pair in
                Button {
                    model.scope = .sources([pair.0])
                } label: {
                    Label(pair.1, systemImage: isScoped(to: pair.0) ? "checkmark" : "")
                }
            }
        } label: {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(scopeLabel)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .glassSurface(cornerRadius: 14)
        }
        .accessibilityLabel("Source scope: \(scopeLabel)")
    }

    private func isScoped(to id: Int64) -> Bool {
        if case .sources(let ids) = model.scope { return ids == [id] }
        return false
    }

    private var scopeLabel: String {
        switch model.scope {
        case .allMusic: return "All music"
        case .sources(let ids):
            if let id = ids.first, let s = appState.sources.first(where: { $0.id == id }) {
                return s.title
            }
            return ids.isEmpty ? "No source selected" : "Selected sources"
        case .playlist: return "Playlist"
        }
    }

    private var musicalFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Musical filters").font(.caption).foregroundStyle(Palette.ink3)
            HStack(spacing: 10) {
                bpmField("Min BPM", text: $model.bpmMinText)
                bpmField("Max BPM", text: $model.bpmMaxText)
                filterField("Key (e.g. 8A)", text: $model.compatibleKey)
                    .frame(maxWidth: 110)
            }
        }
    }

    private func bpmField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .keyboardType(.numberPad)
            .modifier(FilterFieldStyle())
            .accessibilityLabel(label)
    }

    private func filterField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .modifier(FilterFieldStyle())
            .accessibilityLabel(label)
    }

    private var refinements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More like / Less like").font(.caption).foregroundStyle(Palette.ink3)
            Text("Soft preferences — they nudge results, they do not guarantee exclusions.")
                .font(.caption2).foregroundStyle(Palette.ink3)
            FlowChips(
                positives: model.positiveRefinements, negatives: model.negativeRefinements,
                onRemovePositive: model.removeMoreLike, onRemoveNegative: model.removeLessLike)
            HStack(spacing: 8) {
                TextField("Add a term", text: $refinementDraft)
                    .modifier(FilterFieldStyle())
                Button("More") {
                    model.addMoreLike(refinementDraft); refinementDraft = ""
                }
                .buttonStyle(.bordered)
                Button("Less") {
                    model.addLessLike(refinementDraft); refinementDraft = ""
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
        }
    }

    // MARK: - Results / states

    @ViewBuilder
    private var resultsSection: some View {
        switch model.screen {
        case .idle:
            // Real report: "I only see indexed FIND MUSIC but I also want to be able to BROWSE
            // the music I have in the find screen, don't just show it blank... it should show
            // all my music browsing by default, just like the Music tab, but I should then be
            // able to search to filter/find." No query typed yet — show the whole library,
            // reusing the exact same data (`appState.allTracks`) and row (`TrackRowView`) the
            // Library tab uses, so this isn't a second, divergent browse implementation. Typing
            // anything hands off to the existing search/filter machinery below, unchanged.
            if appState.allTracks.isEmpty {
                hint("Your library is empty. Add music to see it here.")
            } else {
                libraryBrowseList
            }
        case .loading:
            HStack { ProgressView(); Text("Searching…").foregroundStyle(Palette.ink3) }
                .font(.callout)
        case .validationError(let issues):
            VStack(alignment: .leading, spacing: 6) {
                Label("Check your filters", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Palette.danger)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Text("• \(issue.description)").font(.footnote).foregroundStyle(Palette.ink2)
                }
            }
        case .results(let kind, let count, let stillIndexing):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(kindLabel(kind)).font(.caption).foregroundStyle(Palette.ink3)
                    Spacer()
                    Text("\(count) result\(count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Palette.ink3)
                }
                if stillIndexing { indexingNote }
                ForEach(model.results, id: \.trackID) { result in
                    DiscoverySearchResultRow(
                        result: result, kind: kind,
                        components: model.scoreComponents(for: result),
                        onPlay: { model.play(result) },
                        onMoreLikeThis: { model.moreLikeThis(trackID: result.trackID) })
                    Divider().overlay(Palette.hairline)
                }
            }
        case .noMatches(let kind):
            hint("No \(kindLabel(kind).lowercased()) matched. Try broadening the text or filters.")
        case .emptyLibrary:
            hint("Your library is empty. Add music to start searching.")
        case .emptyScope:
            hint("No source is selected. Pick a source or choose All music.")
        case .sourceUnavailable:
            hint("That source is no longer available. Choose another scope.")
        case .zeroIndexed:
            VStack(alignment: .leading, spacing: 8) {
                hint("Nothing in this scope is indexed for sound yet.")
                Button("Open sound-index status") { openStatus() }
                    .buttonStyle(.bordered)
            }
        case .modelMissing:
            VStack(alignment: .leading, spacing: 8) {
                hint("Find by sound needs the sound-search model.")
                HStack {
                    Button("Download models") { model.downloadModels() }
                        .buttonStyle(.borderedProminent)
                    Button("Sound-index status") { openStatus() }
                        .buttonStyle(.bordered)
                }
            }
        case .modelDownloadFailed:
            VStack(alignment: .leading, spacing: 8) {
                hint("The sound-search model could not be loaded.")
                Button("Try again") { model.retry() }.buttonStyle(.bordered)
            }
        case .analyzeReference:
            VStack(alignment: .leading, spacing: 8) {
                hint("This track has not been analyzed for sound yet.")
                Button("Analyze this track") { model.analyzeReference() }
                    .buttonStyle(.borderedProminent)
            }
        case .searchFailed:
            VStack(alignment: .leading, spacing: 8) {
                hint("Something went wrong running that search.")
                Button("Retry") { model.retry() }.buttonStyle(.bordered)
            }
        case .staleSuppressed:
            EmptyView()
        }
    }

    /// Browse-everything view for the idle (no query typed) state. `LazyVStack`, not the
    /// eager `ForEach` the (naturally bounded) search-results case below uses — a library can
    /// have thousands of tracks, and this must not instantiate every row up front.
    private var libraryBrowseList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Music").font(.caption).foregroundStyle(Palette.ink3)
                Spacer()
                Text("\(appState.allTracks.count) track\(appState.allTracks.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Palette.ink3)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(appState.allTracks.enumerated()), id: \.element.id) { idx, row in
                    Button {
                        player.play(tracks: appState.allTracks, startAt: idx, source: .library)
                    } label: {
                        TrackRowView(row: row, showArtwork: true)
                    }
                    .buttonStyle(.plain)
                    .trackContextMenu(row)
                    Divider().overlay(Palette.hairline)
                }
            }
        }
    }

    private var indexingNote: some View {
        Label(
            "Still building the sound index — results may be incomplete.",
            systemImage: "clock.arrow.circlepath")
            .font(.caption).foregroundStyle(Palette.ink3)
    }

    private func kindLabel(_ kind: DiscoverySearchResultKind) -> String {
        switch kind {
        case .semantic: return "Sound matches"
        case .similar: return "Similar-sounding tracks"
        case .filterOnly: return "Filtered tracks"
        case .metadataBrowse: return "Metadata matches"
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openStatus() {
        // The Library screen owns the status sheet; nothing to do here
        // beyond whatever it already shows.
    }
}

private struct FilterFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .glassSurface(cornerRadius: 12)
    }
}

/// Wrapped More-like (brass) / Less-like (muted) chips.
private struct FlowChips: View {
    let positives: [String]
    let negatives: [String]
    let onRemovePositive: (String) -> Void
    let onRemoveNegative: (String) -> Void

    var body: some View {
        if positives.isEmpty && negatives.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                ForEach(positives, id: \.self) { term in
                    chip(term, systemImage: "plus", tint: Palette.brass) { onRemovePositive(term) }
                }
                ForEach(negatives, id: \.self) { term in
                    chip(term, systemImage: "minus", tint: Palette.ink3) { onRemoveNegative(term) }
                }
            }
        }
    }

    private func chip(
        _ term: String, systemImage: String, tint: Color, remove: @escaping () -> Void
    ) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.caption2)
                Text(term).font(.footnote)
                Image(systemName: "xmark").font(.caption2)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(tint)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(systemImage == "plus" ? "More like" : "Less like") \(term). Double tap to remove.")
    }
}

private struct DiscoverySearchResultRow: View {
    let result: DiscoverySearchResult
    let kind: DiscoverySearchResultKind
    let components: [RankBreakdownDisplay.Component]
    let onPlay: () -> Void
    let onMoreLikeThis: () -> Void

    @State private var showScore = false

    private var track: Track { result.track.track }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(Palette.ink3).lineLimit(1)
                    if let musical = musicalLine {
                        Text(musical).font(.caption2).foregroundStyle(Palette.ink3)
                    }
                }
                Spacer(minLength: 6)
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(track.title)")
            }
            HStack(spacing: 14) {
                Button(action: onMoreLikeThis) {
                    Label("More like this", systemImage: "wand.and.stars")
                }
                .font(.caption)
                if kind.showsSemanticScore, !components.isEmpty {
                    Button {
                        withAnimation { showScore.toggle() }
                    } label: {
                        Label("Score details", systemImage: showScore ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.brass)

            if showScore {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(components) { component in
                        HStack {
                            Text(component.label).font(.caption2).foregroundStyle(Palette.ink3)
                            Spacer()
                            Text(component.formattedValue)
                                .font(.caption2.monospacedDigit()).foregroundStyle(Palette.ink2)
                        }
                    }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let artist = result.track.artist?.name ?? result.track.album?.artist { parts.append(artist) }
        if let source = result.track.source?.title { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    private var musicalLine: String? {
        var parts: [String] = []
        if let d = track.durationSec { parts.append(TimeFmt.mmss(d)) }
        if let codec = track.codec { parts.append(codec) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
#endif
