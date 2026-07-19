import XCTest
@testable import TonearmCore

@MainActor
final class RemoteLibraryCopyTests: XCTestCase {
    func testCredentialCopyUsesLocalAppleKeychainLanguage() {
        for connector in RemoteConnectorCatalog.all
            where connector.authKind != .folderPicker && connector.authKind != .urlOnly {
            let privacy = connector.guide.sections
                .first { $0.title == "Privacy" }?
                .body ?? ""
            XCTAssertTrue(
                privacy.contains("locally in Apple Keychain"),
                "\(connector.title) privacy copy should mention local Apple Keychain storage"
            )
        }

        let smbPrivacy = RemoteConnectorCatalog.connector(for: .smb)?
            .guide.sections.first { $0.title == "Privacy" }?
            .body ?? ""
        XCTAssertTrue(smbPrivacy.contains("does not store SMB passwords"))
    }

    func testTerminologyUsesMusicAndLibrariesForVisibleCoreLabels() {
        XCTAssertEqual(QueueSource.library.label, "From Music")
        XCTAssertEqual(ProPaywallModel().features.first?.entryPoint, "Settings > Libraries")
    }
}
