import SwiftUI

private enum ProToolsTab: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case tags = "Tags"
    case audio = "Audio"
    case duplicates = "Duplicates"

    var id: String { rawValue }
}

struct ProToolsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var tab: ProToolsTab = .playlists
    @State private var playlistTitle = "Smart Playlist"
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Tool", selection: $tab) {
                        ForEach(ProToolsTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var playlistsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            textField("TITLE", text: $playlistTitle, prompt: "Smart Playlist")
            pickerRow("FIELD", selection: $smartField, values: SmartPlaylistField.allCases)
            pickerRow("MATCH", selection: $smartOperator, values: SmartPlaylistOperator.allCases)
            textField("VALUE", text: $smartValue, prompt: smartField.kind == .number ? "0" : "text")
            Stepper("Limit \(smartLimit)", value: $smartLimit, in: 1...500)
                .font(.system(size: 13.5))
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
                                .foregroundStyle(selectedTrackIDs.contains(row.id) ? Palette.brass : Palette.ink3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.track.title).font(.system(size: 13.5)).lineLimit(1)
                                Text(row.album?.title ?? "Local file")
                                    .font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1)
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
            Toggle("Crossfeed", isOn: crossfeedEnabled).tint(Palette.brassDeep)
            slider("Crossfeed level", value: crossfeedLevel, range: -24...0, display: String(format: "%.0f dB", crossfeedLevel.wrappedValue))
                .disabled(!proAudio.crossfeedEnabled)
                .opacity(proAudio.crossfeedEnabled ? 1 : 0.45)
            Stepper("Convolution taps \(proAudio.convolutionTaps)", value: convolutionTaps, in: 0...ProAudioSettings.maxConvolutionTaps, step: 64)
                .font(.system(size: 13.5))
            Toggle("Bit-perfect requested", isOn: bitPerfectRequested).tint(Palette.brassDeep)

            VStack(alignment: .leading, spacing: 5) {
                Text(bitPerfectPlan.canUseBitPerfect ? "Bit-perfect available" : "Bit-perfect blocked")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(blockerText)
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            .padding(.top, 2)
        }
        .toolPanel()
    }

    private var duplicatesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            primaryButton(scanningDuplicates ? "Scanning" : "Scan Local Files", icon: "doc.on.doc") {
                Task { await scanDuplicates() }
            }
            .disabled(scanningDuplicates)
            messageText(duplicateMessage)

            ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.candidates.count) matches")
                        .font(.system(size: 13.5, weight: .semibold))
                    ForEach(group.candidates, id: \.id) { candidate in
                        Text(candidate.id)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
                Divider().overlay(Palette.hairline)
            }
        }
        .toolPanel()
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
        guard !blockers.isEmpty else { return "No active processing blockers." }
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
            smartMessage = "Created \(created.title)."
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
            tagMessage = "Updated \(count) tracks."
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
            duplicateMessage = duplicateGroups.isEmpty ? "No duplicates found." : "Found \(duplicateGroups.count) groups."
        } catch {
            duplicateMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func toggle(_ id: Int64) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func textField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).kerning(1)
                .foregroundStyle(Palette.ink3)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.ink3))
                .font(.system(size: 12.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
    }

    private func pickerRow<T: CaseIterable & Hashable & RawRepresentable>(
        _ title: String,
        selection: Binding<T>,
        values: T.AllCases
    ) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold)).kerning(1)
                .foregroundStyle(Palette.ink3)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(Array(values), id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .tint(Palette.brass)
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        display: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 13.5))
                Spacer()
                Text(display).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.ink3)
            }
            Slider(value: value, in: range).tint(Palette.brass)
        }
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(Color(hex: 0x221503))
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(Palette.brass, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func messageText(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
        }
    }
}

private extension View {
    func toolPanel() -> some View {
        padding(15).glassSurface(cornerRadius: 18)
    }
}
