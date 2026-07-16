import SwiftUI
import UniformTypeIdentifiers
import TonearmCore

private enum RemoteConnectKind: String, CaseIterable, Identifiable {
    case subsonic
    case webDAV
    case smb
    case jellyfin
    case plex
    case dropbox
    case googleDrive
    case oneDrive
    case pCloud

    var id: String { rawValue }

    var sourceKind: SourceKind {
        switch self {
        case .subsonic: return .subsonic
        case .webDAV: return .webDAV
        case .smb: return .smb
        case .jellyfin: return .jellyfin
        case .plex: return .plex
        case .dropbox: return .dropbox
        case .googleDrive: return .googleDrive
        case .oneDrive: return .oneDrive
        case .pCloud: return .pCloud
        }
    }

    var cloudProvider: CloudDriveAPI.Provider? {
        CloudDriveAPI.Provider(sourceKind: sourceKind)
    }

    var title: String {
        switch self {
        case .subsonic: return "Subsonic"
        case .webDAV: return "WebDAV"
        case .smb: return "SMB"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .pCloud: return "pCloud"
        }
    }

    var subtitle: String {
        switch self {
        case .subsonic: return "Subsonic or Navidrome"
        case .webDAV: return "Nextcloud, ownCloud, rclone"
        case .smb: return "Folder shared through Files"
        case .jellyfin: return "Music library server"
        case .plex: return "Plex music section"
        case .dropbox, .googleDrive, .oneDrive, .pCloud: return "OAuth access token"
        }
    }

    var icon: String {
        switch self {
        case .smb, .webDAV, .dropbox, .googleDrive, .oneDrive, .pCloud:
            return "externaldrive.connected.to.line.below"
        default:
            return "server.rack"
        }
    }

    var needsURL: Bool {
        switch self {
        case .subsonic, .webDAV, .jellyfin, .plex:
            return true
        case .smb, .dropbox, .googleDrive, .oneDrive, .pCloud:
            return false
        }
    }

    var needsUsernamePassword: Bool {
        switch self {
        case .subsonic, .webDAV, .jellyfin:
            return true
        case .smb, .plex, .dropbox, .googleDrive, .oneDrive, .pCloud:
            return false
        }
    }

    var needsToken: Bool {
        switch self {
        case .plex, .dropbox, .googleDrive, .oneDrive, .pCloud:
            return true
        case .subsonic, .webDAV, .smb, .jellyfin:
            return false
        }
    }
}

struct AddServerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var kind: RemoteConnectKind = .subsonic
    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var error: String?
    @State private var isConnecting = false
    @State private var showSMBPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add Remote Library")
                .font(.system(size: 19, weight: .bold)).padding(.top, 12)
            Text(kind.subtitle)
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).padding(.top, 5)

            providerPicker.padding(.top, 16)
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
                        else { actionLabel(title: "Connect \(kind.title)", icon: "checkmark") }
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
        .fileImporter(isPresented: $showSMBPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await connectSMB(url) }
        }
    }

    private var providerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RemoteConnectKind.allCases) { option in
                    Button { kind = option } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon)
                            Text(option.title)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(option == kind ? Color(hex: 0x221503) : Palette.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(option == kind ? Palette.brass : Color.white.opacity(0.08),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fields: some View {
        VStack(spacing: 10) {
            if kind.needsURL {
                textField(label: "SERVER URL",
                          prompt: kind == .plex ? "https://plex.example.com:32400" : "https://music.example.com",
                          text: $urlText,
                          keyboardType: .URL)
            }
            if kind.needsUsernamePassword {
                textField(label: "USERNAME",
                          prompt: "user",
                          text: $username,
                          keyboardType: .default)
                secureField(label: "PASSWORD", prompt: "password", text: $password)
            }
            if kind.needsToken {
                secureField(label: kind == .plex ? "PLEX TOKEN" : "ACCESS TOKEN",
                            prompt: "token",
                            text: $token)
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
            SecureField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.ink3))
                .font(.system(size: 12.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
            return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .smb:
            return true
        }
    }

    private var footerText: String {
        switch kind {
        case .smb:
            return "Folder access is stored as a security-scoped bookmark. Files are not copied."
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return "Tokens are stored in the Keychain. Tonearm lists audio files and resolves streams only on demand."
        default:
            return "Credentials are stored in the Keychain. Tonearm requests a stream URL only when you play."
        }
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
                if let cloudProvider = kind.cloudProvider {
                    try await appState.addCloudDrive(provider: cloudProvider, accessToken: token)
                }
            case .smb:
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
