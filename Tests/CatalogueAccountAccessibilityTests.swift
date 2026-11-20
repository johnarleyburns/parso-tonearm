import Testing
@testable import TonearmCore

@Suite struct CatalogueAccountAccessibilityTests {
    @Test func testSelectedConnectorIsAnnouncedWithoutColor() {
        #expect(CatalogueAccountAccessibility.connectorValue(isSelected: true) == "Selected")
        #expect(CatalogueAccountAccessibility.connectorValue(isSelected: false) == "")
    }

    @Test func testAdvancedConnectorLabelNamesTier() {
        #expect(CatalogueAccountAccessibility.connectorLabel(title: "Plex", isAdvanced: true) == "Plex, advanced")
        #expect(CatalogueAccountAccessibility.connectorLabel(title: "Plex", isAdvanced: false) == "Plex")
    }

    @Test func testErrorAndBusyStateAreSpoken() {
        #expect(CatalogueAccountAccessibility.errorAnnouncement("Bad password") == "Error: Bad password")
        #expect(!CatalogueAccountAccessibility.connectingLabel.isEmpty)
        #expect(CatalogueAccountAccessibility.minimumTargetSide >= 44)
    }
}
