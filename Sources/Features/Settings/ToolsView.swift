import SwiftUI
import TonearmCore

private enum ProToolsTab: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case tags = "Tags"
    case audio = "Audio"
    case duplicates = "Duplicates"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .playlists: "Playlists"
        case .tags: "Tags"
        case .audio: "Audio"
        case .duplicates: "Duplicates"
        }
    }
}

private extension SmartPlaylistField {
    var displayName: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .composer: "Composer"
        case .codec: "Codec"
        case .sourceTitle: "Library name"
        case .sourceKind: "Library type"
        case .assetKind: "File type"
        case .assetLocation: "File location"
        case .year: "Year"
        case .durationSeconds: "Duration (seconds)"
        case .trackNumber: "Track number"
        case .discNumber: "Disc number"
        case .sampleRate: "Sample rate"
        case .sizeBytes: "Size (bytes)"
        case .replayGain: "ReplayGain"
        case .dateAdded: "Date added"
        }
    }
}

private extension SmartPlaylistOperator {
    var displayName: LocalizedStringKey {
        switch self {
        case .contains: "contains"
        case .notContains: "does not contain"
        case .equals: "is"
        case .notEquals: "is not"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        case .greaterThan: "is greater than"
        case .greaterThanOrEqual: "is at least"
        case .lessThan: "is less than"
        case .lessThanOrEqual: "is at most"
        case .between: "is between"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        }
    }
}

struct ToolsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var tab: ProToolsTab = .playlists
    @State private var playlistTitle = String(localized: "Smart Playlist")
    @State private var smartField: SmartPlaylistField = .genre
    @State private var smartOperator: SmartPlaylistOperator = .contains
    @State private var smartValue = ""
    @State private var smartLimit = 50
    @State private var smartMessage: String?

    @State private var selectedTrackIDs: Set<Int64> = []
    @State private var tagGenre = ""
    @State private var tagComposer = ""
    @State private var tagYear = ""
    @State private var tagMessage: String?

    @State private var proAudio = ProAudioSettingsPersistence.load()

    @State private var duplicateGroups: [DuplicateDetection.Group] = []
    @State private var duplicateMessage: String?
    @State private var scanningDuplicates = false
    @State private var eliminatingDuplicates = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Tool", selection: $tab) {
                        ForEach(ProToolsTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case .playlists:
                        playlistsPanel
                    case .tags:
                        tagsPanel
                    case .audio:
                        audioPanel
                    case .duplicates:
                        duplicatesPanel
                    }
                }
                .padding(18)
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .navigationTitle("Tools")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
            }
        }
    }

    private var playlistsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            textField("TITLE", text: $playlistTitle, prompt: "Smart Playlist")
            pickerRow("FIELD", selection: $smartField, values: SmartPlaylistField.allCases, label: \.displayName)
            pickerRow("MATCH", selection: $smartOperator, values: SmartPlaylistOperator.allCases, label: \.displayName)
            textField("VALUE", text: $smartValue, prompt: smartField.kind == .number ? "0" : "text")
            Stepper("Limit \(smartLimit)", value: $smartLimit, in: 1...500)
                .font(Typography.callout)
            primaryButton("Create Playlist", icon: "text.badge.plus") {
                Task { await createSmartPlaylist() }
            }
            messageText(smartMessage)
        }
        .toolPanel()
    }

    private var tagsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                textField("GENRE", text: $tagGenre, prompt: "genre")
                textField("YEAR", text: $tagYear, prompt: "year")
            }
            textField("COMPOSER", text: $tagComposer, prompt: "composer")

            VStack(spacing: 0) {
                ForEach(editableRows.prefix(40)) { row in
                    Button { toggle(row.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedTrackIDs.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedTrackIDs.contains(row.id) ? Palette.accent : Palette.inkTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.track.title).font(Typography.callout).lineLimit(1)
                                Text(row.album?.title ?? String(localized: "Local file"))
                                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Palette.hairline)
                }
            }

            primaryButton("Apply Tags", icon: "tag") {
                Task { await applyTags() }
            }
            .disabled(selectedTrackIDs.isEmpty)
            .opacity(selectedTrackIDs.isEmpty ? 0.45 : 1)
            messageText(tagMessage)
        }
        .toolPanel()
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider("Frequency", value: bandFrequency, range: 20...20_000, display: "\(Int(bandFrequency.wrappedValue)) Hz")
            slider("Gain", value: bandGain, range: -12...12, display: String(format: "%.1f dB", bandGain.wrappedValue))
            slider("Q", value: bandQ, range: 0.2...10, display: String(format: "%.1f", bandQ.wrappedValue))
            Toggle("Crossfeed", isOn: crossfeedEnabled).tint(Palette.accent)
            slider("Crossfeed level", value: crossfeedLevel, range: -24...0, display: String(format: "%.0f dB", crossfeedLevel.wrappedValue))
                .disabled(!proAudio.crossfeedEnabled)
                .opacity(proAudio.crossfeedEnabled ? 1 : 0.45)
            Stepper("Convolution taps \(proAudio.convolutionTaps)", value: convolutionTaps, in: 0...ProAudioSettings.maxConvolutionTaps, step: 64)
                .font(Typography.callout)
            Toggle("Bit-perfect requested", isOn: bitPerfectRequested).tint(Palette.accent)

            VStack(alignment: .leading, spacing: 5) {
                Text(bitPerfectPlan.canUseBitPerfect ? "Bit-perfect available" : "Bit-perfect blocked")
                    .font(Typography.callout)
                Text(blockerText)
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            .padding(.top, 2)
        }
        .toolPanel()
    }

    private var duplicatesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            primaryButton(scanningDuplicates ? "Scanning" : "Search for Duplicates", icon: "doc.on.doc") {
                Task { await scanDuplicates() }
            }
            .disabled(scanningDuplicates)
            messageText(duplicateMessage)

            if !duplicateGroups.isEmpty {
                primaryButton(
                    eliminatingDuplicates ? "Removing…" : "Eliminate \(totalDuplicateCount) Duplicates",
                    icon: "trash"
                ) {
                    Task { await eliminateDuplicates() }
                }
                .disabled(eliminatingDuplicates)
                .accessibilityIdentifier("settings.tools.eliminateDuplicates")
            }

            ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.candidates.count) matches — keeping the first, removing the rest")
                        .font(Typography.callout)
                    ForEach(group.candidates, id: \.id) { candidate in
                        Text(candidate.id)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
                Divider().overlay(Palette.hairline)
            }
        }
        .toolPanel()
    }

    private var totalDuplicateCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.candidates.count - 1 }
    }

    private var editableRows: [TrackRow] {
        appState.allTracks.filter { row in
            TagEdit.editableTrack(from: row).writeAccess.localPath != nil
        }
    }

    private static let parametricBandID = "proaudio.parametric.primary"

    private var primaryBand: ParametricEQBand {
        proAudio.parametricBands.first ?? ParametricEQBand(
            id: Self.parametricBandID, type: .peaking, frequency: 1_000, gainDB: 0, q: 1)
    }

    private func updateBand(_ transform: (inout ParametricEQBand) -> Void) {
        var band = primaryBand
        transform(&band)
        // A 0 dB peaking band is transparent; keep it out of the cascade so the
        // chain can null and bit-perfect stays reachable.
        if band.gainDB == 0 {
            proAudio.parametricBands = []
        } else {
            proAudio.parametricBands = [band]
        }
        commit()
    }

    private func commit() {
        player.updateProAudio(proAudio)
    }

    private var bandFrequency: Binding<Double> {
        Binding(get: { primaryBand.frequency },
                set: { value in updateBand { $0.frequency = value } })
    }

    private var bandGain: Binding<Double> {
        Binding(get: { primaryBand.gainDB },
                set: { value in updateBand { $0.gainDB = value } })
    }

    private var bandQ: Binding<Double> {
        Binding(get: { primaryBand.q },
                set: { value in updateBand { $0.q = value } })
    }

    private var crossfeedEnabled: Binding<Bool> {
        Binding(get: { proAudio.crossfeedEnabled },
                set: { proAudio.crossfeedEnabled = $0; commit() })
    }

    private var crossfeedLevel: Binding<Double> {
        Binding(get: { proAudio.crossfeedDB },
                set: { proAudio.crossfeedDB = $0; commit() })
    }

    private var convolutionTaps: Binding<Int> {
        Binding(get: { proAudio.convolutionTaps },
                set: { proAudio.convolutionTaps = $0; commit() })
    }

    private var bitPerfectRequested: Binding<Bool> {
        Binding(get: { proAudio.bitPerfectRequested },
                set: { proAudio.bitPerfectRequested = $0; commit() })
    }

    private var bitPerfectPlan: BitPerfectOutputPlan {
        player.bitPerfectPlan(for: proAudio)
    }

    private var blockerText: String {
        let blockers = bitPerfectPlan.blockers
        guard !blockers.isEmpty else { return String(localized: "No active processing blockers.") }
        return blockers.map { "\($0)" }.joined(separator: ", ")
    }

    private func createSmartPlaylist() async {
        do {
            let value: SmartPlaylistValue? = smartField.kind == .number
                ? Double(smartValue.trimmingCharacters(in: .whitespacesAndNewlines)).map(SmartPlaylistValue.number)
                : .text(smartValue)
            let rule = SmartPlaylistRule(field: smartField, op: smartOperator, value: value)
            let playlist = SmartPlaylist(
                root: SmartPlaylistRuleGroup(predicates: [.rule(rule)]),
                sort: SmartPlaylist.Sort(field: .title, direction: .ascending),
                limit: smartLimit
            )
            let created = try await appState.createSmartPlaylistSnapshot(title: playlistTitle, playlist: playlist)
            smartMessage = String(localized: "Created \(created.title).")
        } catch {
            smartMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyTags() async {
        var proposal = TagEdit.Proposal()
        let genre = tagGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        let composer = tagComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Int(tagYear.trimmingCharacters(in: .whitespacesAndNewlines))
        if !genre.isEmpty { proposal.assignments[.genre] = .text(genre) }
        if !composer.isEmpty { proposal.assignments[.composer] = .text(composer) }
        if let year { proposal.assignments[.year] = .integer(year) }
        do {
            let count = try await appState.applyTagEdit(trackIDs: selectedTrackIDs, proposal: proposal)
            tagMessage = String(localized: "Updated \(count) tracks.")
            selectedTrackIDs.removeAll()
        } catch {
            tagMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func scanDuplicates() async {
        scanningDuplicates = true
        defer { scanningDuplicates = false }
        do {
            duplicateGroups = try await appState.duplicateGroups()
            duplicateMessage = duplicateGroups.isEmpty ? String(localized: "No duplicates found.") : String(localized: "Found \(duplicateGroups.count) groups.")
        } catch {
            duplicateMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func eliminateDuplicates() async {
        eliminatingDuplicates = true
        defer { eliminatingDuplicates = false }
        let removed = await appState.eliminateDuplicates(in: duplicateGroups)
        duplicateGroups = []
        duplicateMessage = String(localized: "Removed \(removed) duplicate tracks.")
    }

    private func toggle(_ id: Int64) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func textField(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Typography.caption).kerning(1)
                .foregroundStyle(Palette.inkTertiary)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.inkTertiary))
                .font(Typography.callout)
                .platformAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.ink.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.ink.opacity(0.12)))
    }

    private func pickerRow<T: CaseIterable & Hashable & RawRepresentable>(
        _ title: LocalizedStringKey,
        selection: Binding<T>,
        values: T.AllCases,
        label: @escaping (T) -> LocalizedStringKey
    ) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        HStack {
            Text(title).font(Typography.caption).kerning(1)
                .foregroundStyle(Palette.inkTertiary)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(Array(values), id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .tint(Palette.accent)
        }
    }

    private func slider(_ title: LocalizedStringKey,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        display: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(Typography.callout)
                Spacer()
                Text(display).font(Typography.caption.monospacedDigit()).foregroundStyle(Palette.inkTertiary)
            }
            Slider(value: value, in: range).tint(Palette.accent)
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(Typography.callout)
            .foregroundStyle(Palette.accentOnFill)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func messageText(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }
}

private extension View {
    func toolPanel() -> some View {
        padding(15).glassSurface(cornerRadius: 18)
    }
}
