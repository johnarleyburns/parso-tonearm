import SwiftUI

/// The auto-playlist brief (§41.6, mockup `ipad/05a-autoplaylist-brief.html`;
/// compact class §42.4/`iphone/03-autoplaylist.html`). Free tier.
///
/// Natural-language brief → editable "what we understood" chips (§28A.6), the
/// energy-arc picker (six presets incl. draw-your-own, peak marker draggable),
/// the length (duration slider with the ±5% honesty, or a track count), the
/// constraint toggles, and "start from" a seed track. Phone and iPad share the
/// one `AutoPlaylistModel`; on the compact class the generated result renders
/// inline below the form (separated by the generate action, §42.4), on the
/// regular class it pushes to `PlaylistResultView`.
///
/// This file holds the top-level `body` and the brief-field/chips/generate
/// sections; the arc picker, length/constraints, and seed-track sections are
/// extracted into `PlaylistBriefView+ArcPicker.swift`,
/// `PlaylistBriefView+LengthAndConstraints.swift`, and
/// `PlaylistBriefView+Seed.swift` respectively. `model`, `seedSearch`, and
/// `showSeedPicker` are used from those extension files too, so they are kept
/// at the implicit internal access level rather than `private`.
public struct PlaylistBriefView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject var model: AutoPlaylistModel
    @State var showSeedPicker = false
    @State var seedSearch = ""
    @State private var pushResult = false

    public init(model: AutoPlaylistModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                briefField
                understoodChips
                arcPicker
                lengthCard
                constraintsCard
                seedCard
                generateButton
                privacyNote
                if sizeClass == .compact, model.generation != nil {
                    Divider()
                        .padding(.vertical, 6)
                    PlaylistResultView(model: model)
                }
            }
            .padding(20)
        }
        .navigationTitle("Make me a playlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("Free")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Free feature")
            }
        }
        .navigationDestination(isPresented: $pushResult) {
            ScrollView {
                PlaylistResultView(model: model)
                    .padding(20)
            }
            .navigationTitle(model.resultTitle)
        }
        .sheet(isPresented: $showSeedPicker) {
            NavigationStack {
                seedPicker
            }
            .task { await model.loadSeedCandidates() }
        }
    }

    // MARK: - Brief field

    private var briefField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In your own words")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("e.g. two hours for a dinner party — starts warm and conversational, builds after the food…",
                      text: $model.prompt,
                      axis: .vertical)
                .lineLimit(4...8)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.indigo.opacity(0.5), lineWidth: 1))
        }
    }

    // MARK: - Chips (§28A.6, inspectable + editable)

    private var understoodChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What we understood — tap to drop")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if model.chips.isEmpty {
                Text("Nothing to show yet — everything you write also goes to the search model unchanged.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(model.chips) { chip in
                        chipView(chip)
                    }
                }
            }
            Text("Everything we didn't recognise still goes to the search model unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func chipView(_ chip: BriefChip) -> some View {
        Button {
            model.removeChip(chip)
        } label: {
            HStack(spacing: 5) {
                Text(chip.label)
                    .font(.system(size: 12))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(chipBackground(chip.kind), in: Capsule())
            .foregroundStyle(chipForeground(chip.kind))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Drop \(chip.label)")
    }

    private func chipBackground(_ kind: BriefChip.Kind) -> Color {
        switch kind {
        case .positive: return .blue.opacity(0.12)
        case .negative: return .orange.opacity(0.12)
        case .arc: return .indigo.opacity(0.14)
        default: return .gray.opacity(0.16)
        }
    }

    private func chipForeground(_ kind: BriefChip.Kind) -> Color {
        switch kind {
        case .positive: return .blue
        case .negative: return .orange
        case .arc: return .indigo
        default: return .primary
        }
    }

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            Task {
                await model.generate()
                if sizeClass != .compact {
                    pushResult = true
                }
            }
        } label: {
            HStack {
                if model.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating…")
                } else {
                    Image(systemName: "wand.and.stars")
                    Text(model.generation == nil ? "Generate" : "Regenerate")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isGenerating || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var privacyNote: some View {
        Text("Runs entirely on this device · a couple of seconds")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}
