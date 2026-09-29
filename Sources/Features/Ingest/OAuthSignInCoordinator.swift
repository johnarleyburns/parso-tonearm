import AuthenticationServices
import Foundation
import TonearmCore
import UIKit

@MainActor
final class OAuthSignInCoordinator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?
    private let tokenClient = OAuthTokenClient()

    func signIn(config: OAuthProviderConfig) async throws -> OAuthToken {
        let authSession = try OAuthAuthorizationSession(config: config)
        let callbackURL = try await callbackURL(for: authSession)
        return try await tokenClient.exchange(session: authSession, callbackURL: callbackURL)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func callbackURL(for authSession: OAuthAuthorizationSession) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authSession.authorizationURL,
                callbackURLScheme: authSession.config.redirectURI.scheme
            ) { [weak self] url, error in
                defer { self?.webSession = nil }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: OAuthError.invalidRedirect)
                    return
                }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                webSession = nil
                continuation.resume(throwing: OAuthError.invalidRedirect)
            }
        }
    }
}
