import Foundation

/// Where the Jamendo `client_id` comes from, and in what order (§18A.2, §18A.6,
/// plan 6.3 decision 2).
///
/// Two credentials can be in play and they are not the same kind of thing:
///
/// - **The app's own key**, shipped in the binary via `Info.plist`. It is an
///   *application* credential, not a user login — FR-LIB-9's "works with no
///   account" depends on it being there. It never enters the repo: it arrives
///   through an untracked `Config/Secrets.xcconfig` locally and a CI secret for
///   TestFlight (§54.2).
/// - **The user's own key**, typed into Settings and kept in the Keychain. A
///   user who registers at devportal.jamendo.com gets their own rate limit and
///   is not sharing ours.
///
/// The user's key wins when present. That ordering is the point of offering it:
/// if our key is ever rate-limited, revoked, or pulled, a user who supplied
/// their own keeps working — and the feature degrades to the honest
/// `.notConfigured` state rather than to a silently empty library, which is the
/// D-9 lesson.
///
/// The `client_secret` is stored but not used yet: Jamendo v3.0 read access
/// needs only the id, and the secret is for the OAuth authorization flow the
/// app does not perform (it would require an account, which FR-LIB-9 refuses to
/// require). Keeping it means a user pastes both halves once, not twice.
public struct JamendoCredential: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?
    public let isUserSupplied: Bool

    public init(clientID: String, clientSecret: String? = nil, isUserSupplied: Bool) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.isUserSupplied = isUserSupplied
    }
}

/// Reads and writes the user's own Jamendo credential (Keychain), and resolves
/// which credential a request should use.
public struct JamendoCredentialStore: Sendable {

    /// Keychain accounts. The service is the app's existing remote-credential
    /// service, so a user deleting the app takes these with it.
    private static let idAccount = "jamendo.client_id"
    private static let secretAccount = "jamendo.client_secret"

    private let keychain: CredentialStore
    /// The app's own key, injected so tests never depend on a build setting.
    private let appClientID: @Sendable () -> String

    public init(keychain: CredentialStore = CredentialStore(),
                appClientID: @escaping @Sendable () -> String) {
        self.keychain = keychain
        self.appClientID = appClientID
    }

    /// The credential a request should use: the user's if they supplied one,
    /// otherwise the app's, and nil when neither exists.
    ///
    /// nil is a real state and the caller must render it honestly — an
    /// unconfigured build has no library, and pretending otherwise produces an
    /// empty genre picker with no explanation (§18A.6).
    public func resolved() -> JamendoCredential? {
        if let user = userSupplied() { return user }
        let appKey = appClientID().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty else { return nil }
        return JamendoCredential(clientID: appKey, clientSecret: nil, isUserSupplied: false)
    }

    /// The user's own credential, if they have saved one.
    public func userSupplied() -> JamendoCredential? {
        guard let data = try? keychain.read(account: Self.idAccount),
              let id = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let secret = (try? keychain.read(account: Self.secretAccount))
            .flatMap { $0 }
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return JamendoCredential(clientID: id,
                                 clientSecret: (secret?.isEmpty ?? true) ? nil : secret,
                                 isUserSupplied: true)
    }

    /// Save the user's own credential. An empty id clears it, which is how a
    /// user goes back to the app's key without hunting for a delete button.
    public func saveUserSupplied(clientID: String, clientSecret: String?) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            try clearUserSupplied()
            return
        }
        try keychain.save(Data(id.utf8), account: Self.idAccount)
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if secret.isEmpty {
            try? keychain.delete(account: Self.secretAccount)
        } else {
            try keychain.save(Data(secret.utf8), account: Self.secretAccount)
        }
    }

    public func clearUserSupplied() throws {
        try? keychain.delete(account: Self.idAccount)
        try? keychain.delete(account: Self.secretAccount)
    }
}
