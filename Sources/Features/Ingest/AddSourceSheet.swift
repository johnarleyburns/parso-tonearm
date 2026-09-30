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
            Capsule().fill(Palette.ink.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add archive.org Library")
                .font(Typography.headline).padding(.top, 12)
            Text("Paste a link to an item, a public list or\nfavorites page, or a collection.")
                .font(Typography.callout).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center).padding(.top, 5)

            urlField.padding(.top, 16)

            if isResolving {
                ProgressView().tint(Palette.accent).padding(.top, 20)
            } else if let error {
                Text(error).font(Typography.callout).foregroundStyle(Palette.danger)
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
                        if isAdding { ProgressView().tint(Palette.accentOnFill) }
                        else { Text("Add to Music") }
                }
                .font(Typography.body)
                .foregroundStyle(Palette.accentOnFill)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(LinearGradient(colors: [Palette.accent, Palette.accent],
                                           startPoint: .top, endPoint: .bottom),
                            in: Capsule())
            }
            .disabled(preview == nil || isAdding)
            .opacity(preview == nil ? 0.5 : 1)

            Text("Platterhead streams this music and keeps a temporary cache.\nNothing is stored permanently and nothing is searched for you.")
                .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center).padding(.top, 11)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("URL").font(Typography.caption).kerning(1)
                .foregroundStyle(Palette.inkTertiary)
            PasteCapableTextField(text: $urlText, prompt: "https://archive.org/details/…", isSecure: false, keyboardType: .url)
                .frame(height: 28)
                .onChange(of: urlText) { _, _ in
                    Task { await resolve() }
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Palette.ink.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.ink.opacity(0.12)))
    }

    private func previewCard(_ p: SourcePreview) -> some View {
        HStack(spacing: 12) {
            ArtworkView(seed: p.title, cornerRadius: 12).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(Typography.callout).lineLimit(2)
                Text(p.subtitle).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                if let lic = p.licenseText {
                    Text("✓ \(lic)").font(Typography.caption).foregroundStyle(Palette.success)
                } else if p.licensePermitsStreaming {
                    Text("✓ streams permitted").font(Typography.caption).foregroundStyle(Palette.success)
                }
                if p.capHit, let total = p.totalCount {
                    Text("Adds first \(p.memberCount ?? 0) of \(total)")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
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
                Text("Follow list updates").font(Typography.callout)
                Text("Re-check on pull-to-refresh only").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            Toggle("", isOn: $followUpdates).labelsHidden().tint(Palette.accent)
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
