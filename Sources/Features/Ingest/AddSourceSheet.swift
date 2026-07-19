import SwiftUI
import TonearmCore

struct AddSourceSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var followUpdates = true
    @State private var preview: SourcePreview?
    @State private var error: String?
    @State private var isResolving = false
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add archive.org Library")
                .font(.system(size: 19, weight: .bold)).padding(.top, 12)
            Text("Paste a link to an item, a public list or\nfavorites page, or a collection.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).padding(.top, 5)

            urlField.padding(.top, 16)

            if isResolving {
                ProgressView().tint(Palette.brass).padding(.top, 20)
            } else if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center).padding(.top, 14)
            } else if let preview {
                previewCard(preview).padding(.top, 13)
                if preview.kind != .iaItem {
                    followToggle.padding(.top, 13)
                }
            }

            Spacer(minLength: 12)

            Button {
                Task { await add() }
            } label: {
                Group {
                        if isAdding { ProgressView().tint(.black) }
                        else { Text("Add to Music") }
                }
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Color(hex: 0x221503))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(LinearGradient(colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                           startPoint: .top, endPoint: .bottom),
                            in: Capsule())
            }
            .disabled(preview == nil || isAdding)
            .opacity(preview == nil ? 0.5 : 1)

            Text("Tonearm streams this music and keeps a temporary cache.\nNothing is stored permanently and nothing is searched for you.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center).padding(.top, 11)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("URL").font(.system(size: 10, weight: .semibold)).kerning(1)
                .foregroundStyle(Palette.ink3)
            TextField("", text: $urlText, prompt: Text("https://archive.org/details/…").foregroundStyle(Palette.ink3),
                      axis: .vertical)
                .font(.system(size: 12.5, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: urlText) { _, _ in
                    Task { await resolve() }
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }

    private func previewCard(_ p: SourcePreview) -> some View {
        HStack(spacing: 12) {
            ArtworkView(seed: p.title, cornerRadius: 12).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                Text(p.subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                if let lic = p.licenseText {
                    Text("✓ \(lic)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.ok)
                } else if p.licensePermitsStreaming {
                    Text("✓ streams permitted").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.ok)
                }
                if p.capHit, let total = p.totalCount {
                    Text("Adds first \(p.memberCount ?? 0) of \(total)")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
            }
            Spacer()
        }
        .padding(12)
        .glassSurface(cornerRadius: 16)
    }

    private var followToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Follow list updates").font(.system(size: 13.5, weight: .medium))
                Text("Re-check on pull-to-refresh only").font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: $followUpdates).labelsHidden().tint(Palette.brassDeep)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassSurface(cornerRadius: 14)
    }

    private func resolve() async {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        preview = nil; error = nil
        guard text.count > 12 else { return }
        // Validate grammar first for instant feedback without network.
        switch URLGrammar.parse(text) {
        case .failure(let e):
            error = e.errorDescription
            return
        case .success:
            break
        }
        isResolving = true
        defer { isResolving = false }
        do {
            let service = SourceService(preferFLAC: appState.preferFLAC)
            preview = try await service.preview(from: text)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add() async {
        guard let preview else { return }
        isAdding = true
        let pr = preview
        let upd = followUpdates
        dismiss()
        appState.addSourceInBackground(preview: pr, followUpdates: upd)
    }
}
