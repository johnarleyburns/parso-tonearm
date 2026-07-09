import XCTest

final class AddFolderUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Regression for "Add Local Folder does nothing": tapping the add control
    /// then "Add Local Folder" must present a system document picker. Before the
    /// single-`.fileImporter` fix nothing presented (two stacked importers, the
    /// audio one won), so this stayed red.
    func testAddLocalFolderPresentsDocumentPicker() throws {
        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "Add (+) control should be visible")
        addButton.tap()

        let folderItem = app.buttons["Add Local Folder"]
        XCTAssertTrue(folderItem.waitForExistence(timeout: 5), "Add Local Folder menu item should appear")
        folderItem.tap()

        // The Files document picker runs in a separate process. Look for its
        // Cancel affordance either in-app or via the Files UI springboard.
        let inAppCancel = app.buttons["Cancel"]
        if inAppCancel.waitForExistence(timeout: 8) {
            XCTAssertTrue(inAppCancel.exists)
            return
        }

        let filesApp = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let cancel = filesApp.buttons["Cancel"]
        let browse = filesApp.navigationBars.firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8) || browse.waitForExistence(timeout: 8),
                      "A system document picker should appear after tapping Add Local Folder")
    }
}
