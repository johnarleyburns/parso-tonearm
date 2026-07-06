import SwiftUI

struct OnboardingSourceOption: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let url: String
    var selected: Bool = true
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var isFinishing = false
    @State private var options: [OnboardingSourceOption] = [
        .init(title: "Chopin — Musopen",
              subtitle: "Public domain recordings",
              url: "https://archive.org/details/musopen-chopin"),
        .init(title: "Beethoven — Complete Piano Sonatas",
              subtitle: "Artur Schnabel · public domain",
              url: "https://archive.org/details/lp_the-complete-piano-sonatas-on-thirteen-dis_ludwig-van-beethoven-artur-schnabel_0"),
        .init(title: "Bach — Open Goldberg Variations",
              subtitle: "CC0 · Kimiko Ishizaka",
              url: "https://archive.org/details/The_Open_Goldberg_Variations-11823"),
        .init(title: "Bach — Well-Tempered Clavier, Book 1",
              subtitle: "Public domain",
              url: "https://archive.org/details/bach-well-tempered-clavier-book-1")
    ]

    private let intros: [(icon: String, title: String, body: String)] = [
        ("music.note.house.fill", "Welcome to Tonearm",
         "A calm player for public-domain and Creative Commons music streamed from the Internet Archive — and your own local files."),
        ("cloud.fill", "Add sources",
         "Paste any archive.org item, list, favorites page, or collection. Every track lands in your Library instantly. Nothing is downloaded until you press play."),
        ("play.circle.fill", "Listen & keep",
         "Played tracks are cached so they work offline until space is needed. Build playlists, favorite what you love, and jump back in anytime.")
    ]

    var body: some View {
        ZStack {
            Palette.libraryBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(intros.enumerated()), id: \.offset) { idx, intro in
                        introPage(intro).tag(idx)
                    }
                    sourcesPage.tag(intros.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                footer
            }
        }
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled()
    }

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

    private var sourcesPage: some View {
        VStack(spacing: 0) {
            Text("Start your library")
                .font(.system(size: 24, weight: .heavy)).kerning(-0.5)
                .padding(.top, 40)
            Text("These are verified public-domain / CC0 recordings.\nWe’ll add the ones you keep checked.")
                .font(.system(size: 13)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).padding(.top, 6)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($options) { $option in
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
            if page < intros.count {
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

    private var selectedCount: Int { options.filter { $0.selected }.count }

    private func primaryLabel(_ text: String) -> some View {
        Text(text).modifier(PrimaryLabelStyle())
    }

    private func finish() async {
        isFinishing = true
        let urls = options.filter { $0.selected }.map { $0.url }
        await appState.completeOnboarding(sourceURLs: urls)
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
