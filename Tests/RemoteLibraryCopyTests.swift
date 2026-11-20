import Testing
@testable import TonearmCore

@MainActor
@Suite struct RemoteLibraryCopyTests {
    @Test func testCredentialCopyUsesLocalAppleKeychainLanguage() {
        for connector in RemoteConnectorCatalog.all
            where connector.authKind != .folderPicker && connector.authKind != .urlOnly {
            let privacy = connector.guide.sections
                .first { $0.title == "Privacy" }?
                .body ?? ""
            #expect(
                privacy.contains("locally in Apple Keychain"),
                "\(connector.title) privacy copy should mention local Apple Keychain storage"
            )
        }

        let smbPrivacy = RemoteConnectorCatalog.connector(for: .smb)?
            .guide.sections.first { $0.title == "Privacy" }?
            .body ?? ""
        #expect(smbPrivacy.contains("does not store SMB passwords"))
    }

    @Test func testTerminologyUsesMusicAndLibrariesForVisibleCoreLabels() {
        #expect(QueueSource.library.label == "From Music")
    }
}
