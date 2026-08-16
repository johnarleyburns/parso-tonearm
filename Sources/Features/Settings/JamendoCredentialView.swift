import SwiftUI
import TonearmCore

/// "Use my own Jamendo key" (§18A.2, plan 6.3 decision 2).
///
/// The app ships with its own application key so genre libraries work with no
/// account (FR-LIB-9). A user who would rather not share that key — or who
/// wants their own rate limit, or who is here because ours stopped working —
/// registers an application at devportal.jamendo.com and pastes the id here.
/// Theirs then takes precedence.
///
/// It is deliberately not presented as a login. There is no Jamendo *account*
/// involved: this is an application credential, the same kind of thing as the
/// cloud OAuth client ids, and the copy says so — otherwise a user reasonably
/// concludes the "no account needed" promise was a lie.
struct JamendoCredentialView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var clientID: String = ""
    @State private var clientSecret: String = ""
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var usingOwnKey = false

    private let store = JamendoCredentialStore(appClientID: { JamendoAppConfig.bundledClientID })

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(usingOwnKey
                         ? "Genre libraries are using your Jamendo key."
                         : appKeyPresent
                           ? "Genre libraries are using the key built into Platterhead. "
                             + "You can use your own instead."
                           : "This build ships without a Jamendo key, so genre libraries are "
                             + "unavailable until you add one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("jamendo.credential.status")
                }

                Section("Your Jamendo application") {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("jamendo.credential.id")
                    SecureField("Client secret (optional)", text: $clientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("jamendo.credential.secret")
                    Text("Register an application at devportal.jamendo.com. This is an "
                         + "application key, not a Jamendo account — browsing and playback "
                         + "still need no sign-in. The secret is optional and unused today; "
                         + "it is kept for the authorised flows Jamendo requires it for.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Save") { save() }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("jamendo.credential.save")
                    if usingOwnKey {
                        Button("Use Platterhead's key instead", role: .destructive) { clear() }
                            .accessibilityIdentifier("jamendo.credential.clear")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("jamendo.credential.error")
                    }
                }
                if saved {
                    Section {
                        Text("Saved to the keychain on this device.")
                            .font(.footnote).foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Jamendo key")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private var appKeyPresent: Bool {
        !JamendoAppConfig.bundledClientID.isEmpty
    }

    private func load() {
        // The id is shown back so a user can see which key is in force; the
        // secret is never re-displayed, only replaced.
        if let existing = store.userSupplied() {
            clientID = existing.clientID
            usingOwnKey = true
        }
    }

    private func save() {
        do {
            try store.saveUserSupplied(clientID: clientID,
                                       clientSecret: clientSecret.isEmpty ? nil : clientSecret)
            usingOwnKey = !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            saved = true
            errorMessage = nil
            clientSecret = ""
        } catch {
            // A keychain failure is reported, never swallowed: a user who
            // believes their key is saved and finds the library still empty has
            // been told something false.
            errorMessage = "The key could not be saved to the keychain (\(error))."
            saved = false
        }
    }

    private func clear() {
        try? store.clearUserSupplied()
        clientID = ""
        clientSecret = ""
        usingOwnKey = false
        saved = false
    }
}
