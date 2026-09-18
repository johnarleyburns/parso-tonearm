import CarPlay
import UIKit

/// CarPlay entry point (README roadmap item). Registered by class name in
/// `Info.plist`'s `UIApplicationSceneManifest.UISceneConfigurations`
/// (`project.yml` generates both copies) — UIKit instantiates this
/// independently of the SwiftUI `App` scene the phone UI uses.
///
/// The `com.apple.developer.carplay-audio` entitlement itself is
/// currently PULLED from `Tonearm.entitlements`/`Tonearm.Debug.
/// entitlements` — the Apple App ID capability is enabled, but the named
/// provisioning profile CI signs Release with ("Platterhead Profile")
/// hasn't been regenerated to include it yet, which failed the TestFlight
/// archive step outright (docs/plans/carplay-and-competitor-gaps-plan.md
/// has the full incident). This scene delegate and the whole template
/// hierarchy below are ready and inert until that entitlement is re-added
/// — CarPlay simply won't connect to this scene without it.
///
/// Deliberately thin: all state lives in the existing `AudioPlayer`/
/// `LibraryStore` singletons the phone UI already uses, so CarPlay is just
/// another surface over the same playback engine — Now Playing controls
/// come for free from the existing `MPNowPlayingInfoCenter`/
/// `MPRemoteCommandCenter` wiring (`SystemPlaybackBridge`), never
/// duplicated here.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let root = CarPlayRootBuilder.rootTemplate(interfaceController: interfaceController)
        interfaceController.setRootTemplate(root, animated: true, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }
}
