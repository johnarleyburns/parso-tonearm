import SwiftUI

struct AddServerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add Subsonic Server")
                .font(.system(size: 19, weight: .bold)).padding(.top, 12)
            Text("Connect to Subsonic or Navidrome with token authentication.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).padding(.top, 5)

            fields.padding(.top, 18)

            if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center).padding(.top, 14)
            }

            Spacer(minLength: 12)

            Button {
                Task { await connect() }
            } label: {
                Group {
                    if isConnecting { ProgressView().tint(.black) }
                    else { Text("Connect Server") }
                }
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Color(hex: 0x221503))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(LinearGradient(colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                           startPoint: .top, endPoint: .bottom),
                            in: Capsule())
            }
            .disabled(!SubsonicServerPolicy.canSubmit(url: urlText, username: username, password: password)
                      || isConnecting)
            .opacity(SubsonicServerPolicy.canSubmit(url: urlText, username: username, password: password) ? 1 : 0.5)

            Text("Credentials are stored in the Keychain. Tonearm requests a stream URL only when you play.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center).padding(.top, 11)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.height(430)])
        .presentationBackground(.ultraThinMaterial)
    }

    private var fields: some View {
        VStack(spacing: 10) {
            textField(label: "SERVER URL",
                      prompt: "https://music.example.com",
                      text: $urlText,
                      keyboardType: .URL)
            textField(label: "USERNAME",
                      prompt: "user",
                      text: $username,
                      keyboardType: .default)
            secureField
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

    private var secureField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PASSWORD").font(.system(size: 10, weight: .semibold)).kerning(1)
                .foregroundStyle(Palette.ink3)
            SecureField("", text: $password, prompt: Text("password").foregroundStyle(Palette.ink3))
                .font(.system(size: 12.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }

    private func connect() async {
        error = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await appState.addSubsonicServer(url: urlText, username: username, password: password)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
