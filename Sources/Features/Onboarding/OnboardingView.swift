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
              subtitle: "Public domain recordings",
              url: "https://archive.org/details/musopen-chopin"),
        .init(kind: .archiveOrg,
              title: "Beethoven — Complete Piano Sonatas",
              subtitle: "Artur Schnabel · public domain",
              url: "https://archive.org/details/lp_the-complete-piano-sonatas-on-thirteen-dis_ludwig-van-beethoven-artur-schnabel_0"),
        .init(kind: .archiveOrg,
              title: "Bach — Open Goldberg Variations",
              subtitle: "CC0 · Kimiko Ishizaka",
              url: "https://archive.org/details/The_Open_Goldberg_Variations-11823"),
        .init(kind: .archiveOrg,
              title: "Bach — Well-Tempered Clavier, Book 1",
              subtitle: "Public domain",
              url: "https://archive.org/details/bach-well-tempered-clavier-book-1"),
        .init(kind: .subsonicDemo,
              title: "Navidrome — Demo Music",
              subtitle: "Subsonic · an instant music collection",
              url: "https://demo.navidrome.org",
              username: "demo",
              password: "demo"),
        .init(kind: .jellyfinDemo,
              title: "Jellyfin — Demo Server",
              subtitle: "Jellyfin · an instant music collection",
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
                             subtitle: "Jamendo · Creative Commons",
                             url: parent.path, selected: false))
            for child in parent.children {
                out.append(.init(kind: .jamendoGenre, title: "\(parent.name) — \(child.name)",
                                 subtitle: "Jamendo · Creative Commons",
                                 url: child.path, selected: false))
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    private let intros: [(icon: String, title: String, body: String)] = [
        ("music.note.house.fill", "Welcome to Platterhead",
         "A calm player for public-domain and Creative Commons music streamed from the Internet Archive — and your own local files."),
        ("cloud.fill", "Add libraries",
         "Paste any archive.org item, list, favorites page, or collection. Every track lands in Music instantly. Nothing is downloaded until you press play."),
        ("play.circle.fill", "Listen & keep",
         "Played tracks are cached so they work offline until space is needed. Build playlists, favorite what you love, and jump back in anytime. Check out the built-in Ambient playlist with continuous rain, ocean, and flowing water sounds for focus, relaxation, or sleep.")
    ]

    var body: some View {
        ZStack {
            Palette.libraryBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(intros.enumerated()), id: \.offset) { idx, intro in
                        introPage(intro).tag(idx)
                    }
                    localPage.tag(intros.count)
                    sourcesPage.tag(intros.count + 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                footer
            }
        }
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                let bookmark = try? url.bookmarkData(options: [.minimalBookmark],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
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
                .font(.system(size: 62)).foregroundStyle(Palette.brass)
            Text(intro.title).font(.system(size: 26, weight: .heavy)).kerning(-0.5)
                .multilineTextAlignment(.center)
            Text(intro.body)
                .font(.system(size: 15)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer(); Spacer()
        }
    }

    private var localPage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 58)).foregroundStyle(Palette.brass)
            Text("Add your own music")
                .font(.system(size: 24, weight: .heavy)).kerning(-0.5)
                .multilineTextAlignment(.center)
            Text("Import a local folder or individual files.\nThey stay where they are — Platterhead reads them in place.")
                .font(.system(size: 14)).foregroundStyle(Palette.ink2)
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
                Text("Added \(localAddedCount) file\(localAddedCount == 1 ? "" : "s")")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ok)
            }
            Spacer(); Spacer()
        }
    }

    private func localButton(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Palette.brass)
            Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
        }
        .padding(14).glassSurface(cornerRadius: 14)
    }

    private var sourcesPage: some View {
        VStack(spacing: 0) {
            Text("Start your Music")
                .font(.system(size: 24, weight: .heavy)).kerning(-0.5)
                .padding(.top, 40)
            Text("These are verified public-domain / CC0 recordings,\nplus Subsonic and Jellyfin demo servers to hear full libraries.\nWe’ll add the ones you keep checked.")
                .font(.system(size: 13)).foregroundStyle(Palette.ink2)
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
                                    .font(.system(size: 20))
                                    .foregroundStyle(option.selected ? Palette.brass : Palette.ink3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(option.subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(14).glassSurface(cornerRadius: 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if page < lastPage {
                Button { withAnimation { page += 1 } } label: {
                    primaryLabel("Continue")
                }
            } else {
                Button { Task { await finish() } } label: {
                    Group {
                        if isFinishing { ProgressView().tint(.black) }
                        else { Text(selectedCount > 0 ? "Add \(selectedCount) & Get Started" : "Get Started") }
                    }
                    .modifier(PrimaryLabelStyle())
                }
                .disabled(isFinishing)
            }
            Button("Skip for now") { Task { await skip() } }
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink3)
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
            Text("JAMENDO GENRES").font(.system(size: 11, weight: .bold)).kerning(0.5)
                .foregroundStyle(Palette.ink3)
            Spacer()
            Button("Select All") { setAllJamendoGenres(selected: true) }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.brass)
                .accessibilityIdentifier("onboarding.jamendoGenres.selectAll")
            Text("·").foregroundStyle(Palette.ink3)
            Button("Select None") { setAllJamendoGenres(selected: false) }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.brass)
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

    private func primaryLabel(_ text: String) -> some View {
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
                    print("onboarding add subsonic demo error: \(error)")
                }
            case .jellyfinDemo:
                do {
                    try await appState.addJellyfinServer(url: option.url,
                                                         username: option.username ?? "",
                                                         password: option.password ?? "")
                } catch {
                    print("onboarding add jellyfin demo error: \(error)")
                }
            case .jamendoGenre:
                do {
                    try await appState.addGenreLibrary(path: option.url, name: option.title)
                } catch {
                    print("onboarding add jamendo genre error: \(error)")
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
            .font(.system(size: 15.5, weight: .bold))
            .foregroundStyle(Color(hex: 0x221503))
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(LinearGradient(colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                       startPoint: .top, endPoint: .bottom), in: Capsule())
    }
}
