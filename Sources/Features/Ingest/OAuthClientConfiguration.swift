import Foundation
import TonearmCore

enum OAuthClientConfiguration {
    private static let clientIDKey = "TonearmOAuthClientIDs"
    private static let clientSecretKey = "TonearmOAuthClientSecrets"

    static func config(for provider: CloudDriveAPI.Provider) throws -> OAuthProviderConfig {
        let clientID = value(for: provider, dictionaryKey: clientIDKey)
        let clientSecret = value(for: provider, dictionaryKey: clientSecretKey)
        let redirectURI = URL(string: "tonearm://oauth/\(provider.rawValue)")!
        return try OAuthProviderConfig.cloudDrive(
            provider: provider,
            clientID: clientID,
            clientSecret: clientSecret.isEmpty ? nil : clientSecret,
            redirectURI: redirectURI
        )
    }

    private static func value(for provider: CloudDriveAPI.Provider, dictionaryKey: String) -> String {
        let values = Bundle.main.object(forInfoDictionaryKey: dictionaryKey) as? [String: String]
        return values?[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
