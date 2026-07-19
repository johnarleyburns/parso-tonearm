import SwiftUI
import UIKit
import UniformTypeIdentifiers
import TonearmCore

struct AddServerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var oauthCoordinator = OAuthSignInCoordinator()

    @State private var kind: SourceKind = .subsonic
    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var error: String?
    @State private var isConnecting = false
    @State private var showSMBPicker = false
    @State private var showGuide = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add Remote Library")
                .font(.system(size: 19, weight: .bold)).padding(.top, 12)
            Text(connector.subtitle)
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).padding(.top, 5)

            providerPicker.padding(.top, 16)
            guideButton.padding(.top, 10)
            fields.padding(.top, 16)

            if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center).padding(.top, 14)
            }

            Spacer(minLength: 12)

            if kind == .smb {
                Button { showSMBPicker = true } label: {
                    actionLabel(title: "Choose Folder", icon: "folder.badge.plus")
                }
            } else {
                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if isConnecting { ProgressView().tint(.black) }
                        else { actionLabel(title: actionTitle, icon: connector.authKind == .oauth ? "person.crop.circle.badge.checkmark" : "checkmark") }
                    }
                }
                .disabled(!canSubmit || isConnecting)
                .opacity(canSubmit ? 1 : 0.5)
            }

            Text(footerText)
                .font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center).padding(.top, 11)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.height(560)])
        .presentationBackground(.ultraThinMaterial)
        .onChange(of: kind) { _, _ in error = nil }
        .sheet(isPresented: $showGuide) {
            RemoteConnectorGuideView(guide: connector.guide)
        }
        .fileImporter(isPresented: $showSMBPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await connectSMB(url) }
        }
    }

    private var connector: RemoteConnector {
        RemoteConnectorCatalog.connector(for: kind) ?? RemoteConnectorCatalog.all[0]
    }

    private var providerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RemoteConnectorCatalog.all) { option in
                    Button { kind = option.sourceKind } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon)
                            Text(option.title)
                            if option.tier == .advanced {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(option.sourceKind == kind ? Color(hex: 0x221503) : Palette.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(option.sourceKind == kind ? Palette.brass : Color.white.opacity(0.08),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var guideButton: some View {
        Button { showGuide = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                Text("How To: \(connector.title)")
                Spacer()
                Text(connector.tier.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(connector.tier == .advanced ? Palette.brass : Palette.ink3)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var fields: some View {
        VStack(spacing: 10) {
            if needsURL {
                textField(label: "SERVER URL",
                          prompt: kind == .plex ? "https://plex.example.com:32400" : "https://music.example.com",
                          text: $urlText,
                          keyboardType: .URL)
            }
            if needsUsernamePassword {
                textField(label: "USERNAME",
                          prompt: "user",
                          text: $username,
                          keyboardType: .default)
                secureField(label: "PASSWORD", prompt: "password", text: $password)
            }
            if needsToken {
                secureField(label: "PLEX TOKEN",
                            prompt: "token",
                            text: $token)
            }
            if connector.authKind == .oauth {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in with \(connector.title)")
                            .font(.system(size: 13.5))
                        Text("Tonearm requests read-only access for browsing and streaming.")
                            .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
            }
            if kind == .smb {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a shared music folder")
                            .font(.system(size: 13.5))
                        Text("Tonearm saves folder access and streams files in place.")
                            .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
            }
        }
    }

    private func textField(label: String,
                           prompt: String,
                           text: Binding<String>,
                           keyboardType: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).kerning(1)
                .foregroundStyle(Palette.ink3)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.ink3))
                .font(.system(size: 12.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }

    private func secureField(label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).kerning(1)
                .foregroundStyle(Palette.ink3)
            PasteCapableSecureTextField(text: text, prompt: prompt)
                .frame(height: 20)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }

    private func actionLabel(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 15.5, weight: .bold))
        .foregroundStyle(Color(hex: 0x221503))
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(LinearGradient(colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule())
    }

    private var canSubmit: Bool {
        switch kind {
        case .subsonic:
            return SubsonicServerPolicy.canSubmit(url: urlText, username: username, password: password)
        case .webDAV:
            return WebDAVServerPolicy.canSubmit(url: urlText, username: username, password: password)
        case .jellyfin:
            return JellyfinServerPolicy.canSubmit(url: urlText, username: username, password: password)
        case .plex:
            return PlexServerPolicy.canSubmit(url: urlText, token: token)
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return true
        case .smb:
            return true
        default:
            return false
        }
    }

    private var footerText: String {
        switch kind {
        case .smb:
            return "Folder access is stored as a security-scoped bookmark. Files are not copied."
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return "OAuth tokens are stored locally in Apple Keychain. Tonearm lists audio files and resolves streams only on demand."
        default:
            return "Credentials are stored locally in Apple Keychain. Tonearm requests a stream URL only when you play."
        }
    }

    private var actionTitle: String {
        connector.authKind == .oauth ? "Sign In to \(connector.title)" : "Connect \(connector.title)"
    }

    private var needsURL: Bool {
        switch kind {
        case .subsonic, .webDAV, .jellyfin, .plex: return true
        default: return false
        }
    }

    private var needsUsernamePassword: Bool {
        switch kind {
        case .subsonic, .webDAV, .jellyfin: return true
        default: return false
        }
    }

    private var needsToken: Bool {
        kind == .plex
    }

    private func connect() async {
        error = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            switch kind {
            case .subsonic:
                try await appState.addSubsonicServer(url: urlText, username: username, password: password)
            case .webDAV:
                try await appState.addWebDAVServer(url: urlText, username: username, password: password)
            case .jellyfin:
                try await appState.addJellyfinServer(url: urlText, username: username, password: password)
            case .plex:
                try await appState.addPlexServer(url: urlText, token: token)
            case .dropbox, .googleDrive, .oneDrive, .pCloud:
                if let cloudProvider = CloudDriveAPI.Provider(sourceKind: kind) {
                    let config = try OAuthClientConfiguration.config(for: cloudProvider)
                    let oauthToken = try await oauthCoordinator.signIn(config: config)
                    try await appState.addCloudDrive(provider: cloudProvider, oauthToken: oauthToken)
                }
            case .smb:
                return
            default:
                return
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func connectSMB(_ url: URL) async {
        error = nil
        isConnecting = true
        defer { isConnecting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData(options: [.minimalBookmark],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        if accessed { url.stopAccessingSecurityScopedResource() }
        do {
            try await appState.addSMBFolder(url, bookmark: bookmark)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct PasteCapableSecureTextField: UIViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.isSecureTextEntry = true
        textField.textContentType = .password
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .default
        textField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textField.textColor = UIColor.white.withAlphaComponent(0.92)
        textField.tintColor = UIColor(Color(hex: 0xEEB35B))
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        if textField.text != text {
            textField.text = text
        }
        textField.attributedPlaceholder = NSAttributedString(
            string: prompt,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.35)]
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textDidChange(_ textField: UITextField) {
            text = textField.text ?? ""
        }
    }
}
