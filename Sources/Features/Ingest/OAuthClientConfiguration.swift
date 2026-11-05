import Foundation
import TonearmCore

enum OAuthClientConfiguration {
    /// Must stay byte-for-byte identical to the literal `CFBundleURLSchemes` entry registered
    /// in project.yml for `guru.parso.tonearm.google-oauth` — Xcode's Info.plist build-setting
    /// substitution silently collapses a string nested this deep (array > dict > array >
    /// string) to 1 garbage character (confirmed against real archived builds #808/#809), so
    /// this can't be read from Info.plist via `$(TONEARM_GOOGLE_DRIVE_REVERSED_CLIENT_ID)`
    /// either — it's hardcoded here too, for the same reason. If the Google Drive OAuth app is
    /// ever re-created, update both this constant and project.yml's literal together.
    private static let googleDriveReversedClientID = "com.googleusercontent.apps.335073009979-oqjttmqu57crphg658tfjps7mq189t8f"

    /// Compiled in as real Swift string literals (`GeneratedOAuthCredentials`, written by
    /// scripts/generate-project.sh from Config/Secrets.xcconfig on every `make project`), not
    /// read from Info.plist. Four separate fix attempts at threading these through Info.plist's
    /// `$(VAR)` build-setting substitution — a shared dict one level deep, a flat top-level key
    /// matching JamendoClientID's own proven-working shape, pre-declaring the build setting in
    /// Config/Base.xcconfig, and checking generation- vs. build-time divergence — never changed
    /// the symptom: Jamendo's structurally-identical key substituted correctly every time, these
    /// kept reading back empty in the real archived Info.plist. Confirmed by a real-device
    /// report after build #811: still "OAuth is not configured" for both Dropbox and Google
    /// despite the Google URL-scheme fix landing.
    private static func clientID(for provider: CloudDriveAPI.Provider) -> String {
        switch provider {
        case .dropbox: return GeneratedOAuthCredentials.dropboxClientID
        case .googleDrive: return GeneratedOAuthCredentials.googleDriveClientID
        case .oneDrive: return GeneratedOAuthCredentials.oneDriveClientID
        case .pCloud: return GeneratedOAuthCredentials.pCloudClientID
        }
    }

    static func config(for provider: CloudDriveAPI.Provider) throws -> OAuthProviderConfig {
        let clientID = clientID(for: provider)
        let clientSecret = provider == .pCloud ? GeneratedOAuthCredentials.pCloudClientSecret : ""
        let redirectURI = try redirectURI(for: provider)
        return try OAuthProviderConfig.cloudDrive(
            provider: provider,
            clientID: clientID,
            clientSecret: clientSecret.isEmpty ? nil : clientSecret,
            redirectURI: redirectURI
        )
    }

    /// Google's native-app OAuth redirect must be the reversed-client-ID custom scheme
    /// (`com.googleusercontent.apps.<id>`), not the generic `tonearm://oauth/<provider>` scheme
    /// the other three cloud providers use. Google's "iOS" OAuth client type has no free-text
    /// redirect field at all, precisely because it ties the redirect to this scheme, scoped to
    /// whichever app holds that specific client ID — an arbitrary private-use scheme like
    /// `tonearm://` isn't exclusively claimable by one app on iOS, so Google won't accept it for
    /// a native client.
    private static func redirectURI(for provider: CloudDriveAPI.Provider) throws -> URL {
        guard provider == .googleDrive else {
            return URL(string: "tonearm://oauth/\(provider.rawValue)")!
        }
        guard let url = URL(string: "\(googleDriveReversedClientID):/oauth2redirect") else {
            throw OAuthError.invalidClientConfiguration(provider.rawValue)
        }
        return url
    }
}
