#if os(iOS)
import Intents
import TonearmCore
import UIKit

/// App side of SiriKit media requests. The `TonearmSiriIntents` extension
/// answers `INPlayMediaIntent` with `.handleInApp`, and iOS launches this app
/// in the background and asks the app delegate for an in-app handler.
/// `@MainActor`: UIKit always calls `UIApplicationDelegate` methods on the main thread, and
/// `landscapeLocked` is mutated from RootView.swift's (implicitly `@MainActor`) SwiftUI context —
/// isolating the whole type is the correct, non-`@unchecked` way to make that assignment
/// concurrency-safe under Swift 6 strict checking, not an escape hatch.
@MainActor
final class TonearmAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? TonearmPlayMediaHandler() : nil
    }

    /// Set (and immediately followed by `UIViewController.setNeedsUpdateOfSupportedInterfaceOrientations()`
    /// on the key window) by `RootView.swift` whenever `AppState.showDJConsole` changes. Read here
    /// rather than reaching into `AppState` directly, so `supportedInterfaceOrientationsFor:` below
    /// stays a trivial, synchronous lookup UIKit can call without any dependency on SwiftUI state.
    var landscapeLocked = false

    /// Locks to landscape while the DJ console is up; otherwise the app's normal full orientation
    /// set (`Info.plist`'s `UISupportedInterfaceOrientations`) applies everywhere else.
    func application(_ application: UIApplication,
                      supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        landscapeLocked ? .landscape : .all
    }
}

/// Unpacks the extension's placeholder item (`SiriMediaRequest`) and plays it
/// through `TonearmIntentRunner.playSiriRequest`: the same resolvers the App
/// Intents use, so no second matcher and no second playback path.
final class TonearmPlayMediaHandler: NSObject, INPlayMediaIntentHandling {
    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let request = intent.mediaItems?.first?.identifier.flatMap(SiriMediaRequest.init(identifier:))
            ?? SiriMediaRequest(
                query: intent.mediaSearch?.mediaName,
                artist: intent.mediaSearch?.artistName,
                kind: .unspecified
            )
        do {
            try await TonearmIntentRunner.playSiriRequest(request)
            return INPlayMediaIntentResponse(code: .success, userActivity: nil)
        } catch {
            return INPlayMediaIntentResponse(
                code: request.isResume ? .failureNoUnplayedContent : .failure,
                userActivity: nil
            )
        }
    }
}

/// Siri authorization for the app, which gates the CarPlay "Ask Siri"
/// assistant cell. Requested only from a user tap in Settings (CLAUDE.md: no
/// silent/magic background work).
enum SiriAuthorization {
    static var status: INSiriAuthorizationStatus {
        INPreferences.siriAuthorizationStatus()
    }

    static var isAuthorized: Bool {
        status == .authorized
    }

    static func request() async -> INSiriAuthorizationStatus {
        await withCheckedContinuation { continuation in
            INPreferences.requestSiriAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
#endif
