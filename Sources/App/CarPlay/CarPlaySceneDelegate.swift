import CarPlay
import UIKit

/// CarPlay entry point (README roadmap item, unblocked once Apple granted
/// the `com.apple.developer.carplay-audio` entitlement — see
/// `Tonearm.entitlements`/`Tonearm.Debug.entitlements`). Registered by class
/// name in `Info.plist`'s `UIApplicationSceneManifest.UISceneConfigurations`
/// (`project.yml` generates both copies) — UIKit instantiates this
/// independently of the SwiftUI `App` scene the phone UI uses.
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
