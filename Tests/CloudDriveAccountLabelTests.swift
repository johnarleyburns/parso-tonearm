import Foundation
import Testing
@testable import TonearmCore

/// Provider-native account identity, used to persist a Source's account label
/// so detach/reattach reuses the same library. These decode the exact shapes
/// each provider returns from its own "current account" endpoint.
@Suite struct CloudDriveAccountLabelTests {
    private func label(_ json: String, _ provider: CloudDriveAPI.Provider) -> String? {
        CloudDriveAPI.decodeAccountLabel(provider: provider, data: Data(json.utf8))
    }

    @Test func testOneDriveUsesUserPrincipalNameThenMailThenID() {
        #expect(label(#"{"id":"abc","userPrincipalName":"me@contoso.com","mail":"other@contoso.com"}"#,
                      .oneDrive) == "me@contoso.com")
        #expect(label(#"{"id":"abc","mail":"me@contoso.com"}"#, .oneDrive) == "me@contoso.com")
        #expect(label(#"{"id":"abc"}"#, .oneDrive) == "abc")
        #expect(label(#"{}"#, .oneDrive) == nil)
    }

    @Test func testGoogleDriveUsesAboutUserEmail() {
        #expect(label(#"{"user":{"emailAddress":"me@gmail.com","permissionId":"123"}}"#,
                      .googleDrive) == "me@gmail.com")
        #expect(label(#"{"user":{"permissionId":"123"}}"#, .googleDrive) == "123")
    }

    @Test func testDropboxUsesEmailThenAccountID() {
        #expect(label(#"{"account_id":"dbid","email":"me@example.com"}"#,
                      .dropbox) == "me@example.com")
        #expect(label(#"{"account_id":"dbid"}"#, .dropbox) == "dbid")
    }

    @Test func testBoxAndPCloudAndYandex() {
        #expect(label(#"{"id":"42","login":"me@box.com"}"#, .box) == "me@box.com")
        #expect(label(#"{"userid":42,"email":"me@pcloud.com"}"#, .pCloud) == "me@pcloud.com")
        #expect(label(#"{"user":{"login":"me","uid":"42"}}"#, .yandexDisk) == "me")
    }

    @Test func testMalformedResponseIsNilNotACrash() {
        #expect(label("not json", .oneDrive) == nil)
        #expect(label("[]", .googleDrive) == nil)
        #expect(label(#"{"email":""}"#, .dropbox) == nil)
    }
}
