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

    /// Info.plist keys, one flat top-level key per provider — NOT nested inside a shared dict.
    /// The same build-setting substitution bug that broke the Google URL scheme (see above) also
    /// broke this when it was `TonearmOAuthClientIDs[provider]`/`TonearmOAuthClientSecrets[provider]`
    /// (a dict one level deep): every provider's client ID read back empty even with the right
    /// GitHub Actions secret set and written into Secrets.xcconfig during the build — confirmed
    /// by a real-device report after build #811, still failing with "OAuth is not configured"
    /// for both Dropbox and Google despite the Google URL-scheme fix landing. JamendoClientID is
    /// the one key in this file proven to substitute correctly, and it's flat/top-level — not
    /// nested in any dict — which is the one structural difference that matters here.
    private static func clientIDKey(for provider: CloudDriveAPI.Provider) -> String {
        switch provider {
        case .dropbox: return "TonearmDropboxClientID"
        case .googleDrive: return "TonearmGoogleDriveClientID"
        case .oneDrive: return "TonearmOneDriveClientID"
        case .pCloud: return "TonearmPCloudClientID"
        }
    }

    static func config(for provider: CloudDriveAPI.Provider) throws -> OAuthProviderConfig {
        let clientID = stringValue(forInfoDictionaryKey: clientIDKey(for: provider))
        let clientSecret = provider == .pCloud ? stringValue(forInfoDictionaryKey: "TonearmPCloudClientSecret") : ""
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

    private static func stringValue(forInfoDictionaryKey key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
