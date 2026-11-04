import Foundation
import TonearmCore

enum OAuthClientConfiguration {
    private static let clientIDKey = "TonearmOAuthClientIDs"
    private static let clientSecretKey = "TonearmOAuthClientSecrets"
    private static let googleReversedClientIDKey = "TonearmGoogleDriveReversedClientID"

    static func config(for provider: CloudDriveAPI.Provider) throws -> OAuthProviderConfig {
        let clientID = value(for: provider, dictionaryKey: clientIDKey)
        let clientSecret = value(for: provider, dictionaryKey: clientSecretKey)
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
        let reversedClientID = (Bundle.main.object(forInfoDictionaryKey: googleReversedClientIDKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reversedClientID.isEmpty, let url = URL(string: "\(reversedClientID):/oauth2redirect") else {
            throw OAuthError.invalidClientConfiguration(provider.rawValue)
        }
        return url
    }

    private static func value(for provider: CloudDriveAPI.Provider, dictionaryKey: String) -> String {
        let values = Bundle.main.object(forInfoDictionaryKey: dictionaryKey) as? [String: String]
        return values?[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
