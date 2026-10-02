import SwiftUI
import TonearmCore

struct OnboardingSourceOption: Identifiable {
    enum Kind: Equatable {
        case archiveOrg
        case subsonicDemo
        case jellyfinDemo
        /// A curated Jamendo genre library (§18A) offered as an optional,
        /// unchecked-by-default onboarding pick — "include in the (optional)
        /// onboarding pre-selected genre music to help populate their
        /// library". `url` carries the genre path (e.g. "electronic/ambient"),
        /// matching `Source.iaIdentifier`'s convention for `.jamendoGenre`.
        case jamendoGenre
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let url: String
    var username: String?
    var password: String?
    var selected: Bool = true
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var isFinishing = false
    @State private var showFolderImporter = false
    @State private var showFileImporter = false
    @State private var localAddedCount = 0
    @State private var pickedFolder: URL?
    @State private var pickedFolderBookmark: Data?
    @State private var options: [OnboardingSourceOption] = [
        .init(kind: .archiveOrg,
              title: "Chopin — Musopen",
              subtitle: String(localized: "Public domain recordings"),
              url: "https://archive.org/details/musopen-chopin"),
        .init(kind: .archiveOrg,
              title: "Beethoven — Complete Piano Sonatas",
              subtitle: String(localized: "Artur Schnabel · public domain"),
              url: "https://archive.org/details/lp_the-complete-piano-sonatas-on-thirteen-dis_ludwig-van-beethoven-artur-schnabel_0"),
        .init(kind: .archiveOrg,
              title: "Bach — Open Goldberg Variations",
              subtitle: "CC0 · Kimiko Ishizaka",
              url: "https://archive.org/details/The_Open_Goldberg_Variations-11823"),
        .init(kind: .archiveOrg,
              title: "Bach — Well-Tempered Clavier, Book 1",
              subtitle: String(localized: "Public domain"),
              url: "https://archive.org/details/bach-well-tempered-clavier-book-1"),
        .init(kind: .subsonicDemo,
              title: "Navidrome — Demo Music",
              subtitle: String(localized: "Subsonic · an instant music collection"),
              url: "https://demo.navidrome.org",
              username: "demo",
              password: "demo"),
        .init(kind: .jellyfinDemo,
              title: "Jellyfin — Demo Server",
              subtitle: String(localized: "Jellyfin · an instant music collection"),
              url: "https://demo.jellyfin.org/stable",
              username: "demo",
              password: ""),
    ] + OnboardingView.jamendoGenreOptions

    /// Real report: "the Jamendo onboarding genres are much too sparse, I
    /// want genres + subgenres n-levels deep essentially exposing every
    /// genre category that jamendo has." Replaces the previous 8 hardcoded
    /// top-level-only picks with the full, real `JamendoGenreTree` (built
    /// from live-verified Jamendo tags, not invented names — see that
    /// type's doc comment) — every top-level genre AND every subgenre, so a
    /// user can pick down to "Rock — Shoegaze" rather than only "Rock".
    /// Sorted alphabetically per that same report; all unchecked by default
    /// (§18A.2, unchanged from before).
    private static let jamendoGenreOptions: [OnboardingSourceOption] = {
        var out: [OnboardingSourceOption] = []
        for parent in JamendoGenreTree.roots {
            out.append(.init(kind: .jamendoGenre, title: parent.name,
                             subtitle: String(localized: "Jamendo · Creative Commons"),
                             url: parent.path, selected: false))
            for child in parent.children {
                out.append(.init(kind: .jamendoGenre, title: "\(parent.name) — \(child.name)",
                                 subtitle: String(localized: "Jamendo · Creative Commons"),
                                 url: child.path, selected: false))
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    private let intros: [(icon: String, title: String, body: String)] = [
        ("music.note.house.fill", String(localized: "Welcome to Platterhead"),
         "A calm player for public-domain and Creative Commons music streamed from the Internet Archive — and your own local files."),
        ("cloud.fill", String(localized: "Add libraries"),
         String(localized: "Paste any archive.org item, list, favorites page, or collection. Every track lands in Music instantly. Nothing is downloaded until you press play.")),
        ("play.circle.fill", String(localized: "Listen & keep"),
         String(localized: "Played tracks are cached so they work offline until space is needed. Build playlists, favorite what you love, and jump back in anytime. Check out the built-in Ambient playlist with continuous rain, ocean, and flowing water sounds for focus, relaxation, or sleep."))
    ]

    var body: some View {
        ZStack {
            Palette.libraryBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                #if os(iOS)
                TabView(selection: $page) {
                    ForEach(Array(intros.enumerated()), id: \.offset) { idx, intro in
                        introPage(intro).tag(idx)
                    }
                    localPage.tag(intros.count)
                    sourcesPage.tag(intros.count + 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                #else
                // macOS has no paged TabView: one page at a time, stepped by
                // the footer's Back / Continue buttons.
                Group {
                    if page < intros.count {
                        introPage(intros[page])
                    } else if page == intros.count {
                        localPage
                    } else {
                        sourcesPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif

                footer
            }
        }
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                let bookmark = BookmarkVault.makeBookmark(for: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    pickedFolder = url
                    pickedFolderBookmark = bookmark
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task {
                    await IngestService().addFiles(urls, into: appState.store)
                    localAddedCount += urls.count
                    await appState.reload()
                }
            }
        }
        .sheet(item: $pickedFolder) { url in
            AddFolderSheet(folderURL: url, folderBookmark: pickedFolderBookmark)
        }
    }

    private var lastPage: Int { intros.count + 1 }

    private func introPage(_ intro: (icon: String, title: String, body: String)) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: intro.icon)
                .font(Typography.display).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(intro.title).font(Typography.title).kerning(-0.5)
                .multilineTextAlignment(.center)
            Text(intro.body)
                .font(Typography.body).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer(); Spacer()
        }
    }

    private var localPage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(Typography.display).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Add your own music")
                .font(Typography.title).kerning(-0.5)
                .multilineTextAlignment(.center)
            Text("Import a local folder or individual files.\nThey stay where they are — Platterhead reads them in place.")
                .font(Typography.callout).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)

            VStack(spacing: 10) {
                Button { showFolderImporter = true } label: {
                    localButton(icon: "folder", title: "Add Local Folder")
                }
                Button { showFileImporter = true } label: {
                    localButton(icon: "music.note", title: "Add Files")
                }
            }
            .padding(.horizontal, 30).padding(.top, 6)

            if localAddedCount > 0 {
                Text("Added \(localAddedCount) files")
                    .font(Typography.callout).foregroundStyle(Palette.success)
            }
            Spacer(); Spacer()
        }
    }

    private func localButton(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(Typography.body).foregroundStyle(Palette.accent)
            ViewThatFits(in: .horizontal) {
                Text(title).font(Typography.body).foregroundStyle(Palette.ink).lineLimit(1)
                Text(title).font(Typography.body).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
        }
        .padding(14).glassSurface(cornerRadius: 14)
    }

    private var sourcesPage: some View {
        VStack(spacing: 0) {
            Text("Start your Music")
                .font(Typography.title).kerning(-0.5)
                .padding(.top, 40)
            Text("These are verified public-domain / CC0 recordings,\nplus Subsonic and Jellyfin demo servers to hear full libraries.\nWe’ll add the ones you keep checked.")
                .font(Typography.callout).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center).padding(.top, 6)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($options) { $option in
                        if option.kind == .jamendoGenre,
                           options.first(where: { $0.kind == .jamendoGenre })?.id == option.id {
                            jamendoGenreSectionHeader
                        }
                        Button { option.selected.toggle() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.selected ? "checkmark.circle.fill" : "circle")
                                    .font(Typography.headline)
                                    .foregroundStyle(option.selected ? Palette.accent : Palette.inkTertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).font(Typography.callout).lineLimit(1)
                                    Text(option.subtitle).font(Typography.caption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(14).glassSurface(cornerRadius: 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityValue(option.selected ? "Selected" : "Not selected")
                        .accessibilityHint(option.selected ? "Double-tap to remove this source" : "Double-tap to add this source")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            #if os(macOS)
            if page > 0 {
                Button("Back") { Motion.perform { page -= 1 } }
                    .font(Typography.callout)
                    .disabled(isFinishing)
            }
            #endif
            if page < lastPage {
                Button { Motion.perform { page += 1 } } label: {
                    primaryLabel("Continue")
                }
            } else {
                Button { Task { await finish() } } label: {
                    Group {
                        if isFinishing { ProgressView().tint(Palette.accentOnFill) }
                        else { Text(selectedCount > 0 ? "Add \(selectedCount) & Get Started" : "Get Started") }
                    }
                    .modifier(PrimaryLabelStyle())
                }
                .disabled(isFinishing)
            }
            Button("Skip for now") { Task { await skip() } }
                .font(Typography.callout).foregroundStyle(Palette.inkTertiary)
                .disabled(isFinishing)
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
    }

    /// Real report: "select ZERO by default instead have a SELECT ALL and
    /// SELECT NONE so they can easily pick" — with 155 real Jamendo genre/
    /// subgenre entries now in this list (JamendoGenreTree.roots' full
    /// depth, not just 8 top-level picks), bulk selection is what makes the
    /// list usable at all. Scoped to Jamendo entries only — the curated
    /// archive.org/demo-server sources above keep their own independent
    /// checked state.
    private var jamendoGenreSectionHeader: some View {
        HStack {
            Text("JAMENDO GENRES").font(Typography.caption).kerning(0.5)
                .foregroundStyle(Palette.inkTertiary)
            Spacer()
            Button("Select All") { setAllJamendoGenres(selected: true) }
                .font(Typography.caption).foregroundStyle(Palette.accent)
                .accessibilityIdentifier("onboarding.jamendoGenres.selectAll")
            Text("·").foregroundStyle(Palette.inkTertiary)
            Button("Select None") { setAllJamendoGenres(selected: false) }
                .font(Typography.caption).foregroundStyle(Palette.accent)
                .accessibilityIdentifier("onboarding.jamendoGenres.selectNone")
        }
        .padding(.top, 12)
    }

    private func setAllJamendoGenres(selected: Bool) {
        for index in options.indices where options[index].kind == .jamendoGenre {
            options[index].selected = selected
        }
    }

    private var selectedCount: Int { options.filter { $0.selected }.count }

    private func primaryLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).modifier(PrimaryLabelStyle())
    }

    private func finish() async {
        isFinishing = true
        let selected = options.filter { $0.selected }
        let archiveURLs = selected.filter { $0.kind == .archiveOrg }.map { $0.url }
        if !archiveURLs.isEmpty {
            await appState.completeOnboarding(sourceURLs: archiveURLs)
        }
        for option in selected {
            switch option.kind {
            case .subsonicDemo:
                do {
                    try await appState.addSubsonicServer(url: option.url,
                                                         username: option.username ?? "",
                                                         password: option.password ?? "")
                } catch {
                    AppLogger.onboarding.error("Adding Subsonic demo failed: \(error.localizedDescription, privacy: .public)")
                }
            case .jellyfinDemo:
                do {
                    try await appState.addJellyfinServer(url: option.url,
                                                         username: option.username ?? "",
                                                         password: option.password ?? "")
                } catch {
                    AppLogger.onboarding.error("Adding Jellyfin demo failed: \(error.localizedDescription, privacy: .public)")
                }
            case .jamendoGenre:
                do {
                    try await appState.addGenreLibrary(path: option.url, name: option.title)
                } catch {
                    AppLogger.onboarding.error("Adding Jamendo genre failed: \(error.localizedDescription, privacy: .public)")
                }
            case .archiveOrg:
                break
            }
        }
        appState.didOnboard = true
        await appState.reload()
        isFinishing = false
    }

    private func skip() async {
        appState.didOnboard = true
    }
}

struct PrimaryLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typography.body)
            .foregroundStyle(Palette.accentOnFill)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(LinearGradient(colors: [Palette.accent, Palette.accent],
                                       startPoint: .top, endPoint: .bottom), in: Capsule())
    }
}
