import AuthenticationServices
import Foundation
import TonearmCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class OAuthSignInCoordinator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?
    private let tokenClient = OAuthTokenClient()

    func signIn(config: OAuthProviderConfig) async throws -> OAuthToken {
        let authSession = try OAuthAuthorizationSession(config: config)
        let callbackURL = try await callbackURL(for: authSession)
        return try await tokenClient.exchange(session: authSession, callbackURL: callbackURL)
    }

    // `ASPresentationAnchor` is a cross-platform typealias (`UIWindow` on
    // iOS, `NSWindow` on macOS) — `ASWebAuthenticationPresentationContextProviding`
    // itself needs no porting, only the platform-specific way of finding the
    // current key window (native Mac app, docs/plans/native-mac-app-plan.md §2a).
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
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
