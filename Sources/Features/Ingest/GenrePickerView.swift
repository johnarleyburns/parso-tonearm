import SwiftUI
import TonearmCore

/// The §41.1a genre picker (mockup `ipad/15-genre-picker.html`, plan 5.6,
/// FR-LIB-9/10). A skippable, free, no-account first-run step and a normal
/// entry in **Add source** (§18A.3) — two doors to the same picker.
///
/// `GenrePickerContent` is the shared body (the genre grid + the
/// selection/attribution card); the sheet wrapper adds the header and the
/// Skip / Add footer. First-run onboarding embeds `GenrePickerContent` in its
/// own page with its own footer.
///
/// Three rules from §41.1a are visible here: **Skip is equally weighted**
/// (a user with their own collection is never herded through this),
/// **no account is requested** (the checkbox is collapsed and gates nothing,
/// §18A.2), and **licensing is stated once, up front** — attribution follows
/// the track into the mix's cue-sheet automatically (§18A.5).
public enum GenrePickerContext: Sendable {
    /// First run — the mockup's "Step 2 · optional".
    case firstRun
    /// From **Add source** — the same picker, different framing.
    case addSource
}

/// A sheet presenting the genre picker. `createSource` is the app-side seam
/// that turns a selection into a `Source(kind: .jamendoGenre)` row.
public struct GenrePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GenrePickerModel
    private let context: GenrePickerContext

    public init(context: GenrePickerContext = .addSource,
                createSource: ((GenrePickerModel.Selection) async throws -> Void)? = nil) {
        self.context = context
        let model = GenrePickerModel()
        model.createSource = createSource
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.ink.opacity(0.35)).frame(width: 36, height: 5)
                .padding(.top, 14)
            header.padding(.top, 14)

            ScrollView {
                GenrePickerContent(model: model)
                    .padding(.horizontal, 22)
            }
            .padding(.top, 6)

            footer
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 22)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.background.ignoresSafeArea())
        .task {
            // The §18A.6 reachability probe: one cheap count fetch on open.
            // A permanent failure surfaces the honest error banner.
            if let first = model.roots.first {
                await model.loadCount(for: first)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            if context == .firstRun {
                Text("Step 2 · optional")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Text("Want some music to practise with?")
                .font(Typography.headline).kerning(-0.4)
                .multilineTextAlignment(.center)
            Text("Pick the genres you want to mix. Each one becomes its own "
                 + "library, ordered by what's most interesting right now — so "
                 + "you can build a set from techno without wading through "
                 + "everything else.")
                .font(Typography.callout)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text(context == .firstRun ? "Skip — I have my own music" : "Cancel")
                    .font(Typography.body)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Palette.ink.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    if await model.addSelected() {
                        dismiss()
                    }
                }
            } label: {
                Group {
                    if model.isAdding {
                        ProgressView().tint(Palette.accentOnFill)
                    } else {
                        Text("Add \(model.selectedGenres.count) libraries")
                    }
                }
                .font(Typography.body)
                .foregroundStyle(Palette.accentOnFill)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.selectedGenres.isEmpty || model.isAdding)
            .opacity(model.selectedGenres.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("genre.add")
        }
    }
}

/// The shared genre-picker body: the expandable genre grid, the selection
/// summary card, the (gating-nothing) account checkbox and the licence note.
/// Used by the sheet above and by first-run onboarding's page.
public struct GenrePickerContent: View {
    @ObservedObject var model: GenrePickerModel
    @State private var expandedPaths: Set<String> = []

    public init(model: GenrePickerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 14) {
            if let error = model.catalogueError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(Typography.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("genre.error")
            }

            LazyVStack(spacing: 10) {
                ForEach(model.roots) { root in
                    genreCard(root)
                }
            }
            .accessibilityIdentifier("genre.grid")

            summaryCard
        }
    }

    private func genreCard(_ node: JamendoGenreNode) -> some View {
        let selected = model.isSelected(node)
        let expanded = expandedPaths.contains(node.path)
        let count = model.counts[node.path]

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    model.toggle(node)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(Typography.headline)
                            .foregroundStyle(selected ? Palette.accent : Palette.inkSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .font(Typography.body)
                                .foregroundStyle(Palette.ink)
                            if let count {
                                Text("about \(count) tracks")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(node.name))
                .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
                .accessibilityIdentifier("genre.\(node.path)")

                if !node.children.isEmpty {
                    Button {
                        Motion.perform(Motion.standard) {
                            if expanded { expandedPaths.remove(node.path) }
                            else { expandedPaths.insert(node.path) }
                            Task { await model.loadCount(for: node) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .accessibilityLabel(expanded ? Text("Hide subgenres of \(node.name)") : Text("Show subgenres of \(node.name)"))
                            .padding(.trailing, 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("genre.expand.\(node.path)")
                }
            }

            if expanded && !node.children.isEmpty {
                HStack(spacing: 6) {
                    ForEach(node.children) { child in
                        let childSelected = model.isSelected(child)
                        Button {
                            model.toggle(child)
                        } label: {
                            Text(child.name)
                                .font(Typography.caption)
                                .foregroundStyle(childSelected ? Palette.accentOnFill : Palette.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    childSelected
                                        ? Palette.accent
                                        : Palette.ink.opacity(0.07),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("genre.\(child.path)")
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink.opacity(0.07), lineWidth: 1))
    }

    private var summaryCard: some View {
        let selections = model.selectedGenres
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selections.isEmpty
                         ? String(localized: "No genres picked")
                         : String(localized: "\(selections.count) libraries") + " · "
                           + selections.map(\.name).joined(separator: ", "))
                        .font(Typography.callout)
                        .foregroundStyle(Palette.ink)
                    Text("We'll fetch the track lists now — that's quick. Audio "
                         + "downloads only when you actually play or prepare a "
                         + "track, so nothing fills your disk in the background.")
                        .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Text("Free")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Palette.accent.opacity(0.14),
                                in: Capsule())
            }

            Divider().overlay(Palette.ink.opacity(0.1))

            HStack(spacing: 9) {
                Image(systemName: model.showsAccountOption
                      ? "checkmark.square.fill" : "square")
                    .font(Typography.headline)
                    .foregroundStyle(model.showsAccountOption
                                     ? Palette.accent
                                     : Palette.inkSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { model.showsAccountOption.toggle() }
                Text("I have a catalogue account (optional) — signing in adds "
                     + "your favourites and playlists. **Browsing and playing "
                     + "work without it.**")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("genre.account.optional")

            Text("These tracks are Creative-Commons licensed. Platterhead keeps "
                 + "each track's artist and licence with it, and adds them to "
                 + "your mix's tracklist automatically — so a set you post is "
                 + "properly credited.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .lineSpacing(2)
        }
        .padding(14)
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink.opacity(0.07), lineWidth: 1))
        .accessibilityIdentifier("genre.summary")
    }
}
