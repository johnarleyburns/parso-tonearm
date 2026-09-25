#if !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// CarPlay entry point (README roadmap item). Registered by class name in
/// `Info.plist`'s `UIApplicationSceneManifest.UISceneConfigurations`
/// (`project.yml` generates both copies) — UIKit instantiates this
/// independently of the SwiftUI `App` scene the phone UI uses.
///
/// Requires the `com.apple.developer.carplay-audio` entitlement, declared in
/// `Tonearm.entitlements`/`Tonearm.Debug.entitlements` (it was briefly pulled
/// while the "Platterhead Profile" was regenerated —
/// docs/plans/carplay-and-competitor-gaps-plan.md has that incident).
///
/// Deliberately thin: all state lives in the existing `AudioPlayer`/
/// `LibraryStore` singletons the phone UI already uses, so CarPlay is just
/// another surface over the same playback engine — Now Playing controls
/// come for free from the existing `MPNowPlayingInfoCenter`/
/// `MPRemoteCommandCenter` wiring (`SystemPlaybackBridge`), never
/// duplicated here.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    /// Library search; only exists where `CPSearchTemplate` is allowed for
    /// this app category (iOS 27+). Held here for the connection's lifetime.
    private var search: CarPlaySearchController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        search = CarPlaySearchAvailability.templateSupported
            ? CarPlaySearchController(interfaceController: interfaceController)
            : nil
        let root = CarPlayRootBuilder.rootTemplate(interfaceController: interfaceController, search: search)
        interfaceController.setRootTemplate(root, animated: true, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        search = nil
    }
}
#endif
