import XCTest
@testable import TonearmCore

final class EQSettingsTests: XCTestCase {
    private let store = EQSettingsStore()

    func testClampsAtBothRails() {
        let settings = EQSettings(
            bands: [-40, -12, -6, 0, 6, 12, 40, 1, 2, 3],
            enabled: true,
            activePresetID: nil
        )
        XCTAssertEqual(store.normalized(settings).bands, [-12, -12, -6, 0, 6, 12, 12, 1, 2, 3])
    }

    func testPresetResolution() {
        XCTAssertEqual(store.bands(forPresetID: EQPreset.spoken.id), EQPreset.spoken.floatGains)
    }

    func testPresetModifiedAndReselectRoundTrip() {
        var settings = store.applyingPreset(id: EQPreset.concertHall.id, to: .flat)
        XCTAssertFalse(store.isModifiedFromPreset(settings))

        settings = store.updatingBand(at: 0, to: 7, in: settings)
        XCTAssertTrue(store.isModifiedFromPreset(settings))

        settings = store.applyingPreset(id: EQPreset.concertHall.id, to: settings)
        XCTAssertFalse(store.isModifiedFromPreset(settings))
        XCTAssertEqual(settings.bands, EQPreset.concertHall.floatGains)
    }

    func testUnknownPresetFallsBackToFlat() {
        let settings = store.applyingPreset(id: "missing", to: EQSettings(
            bands: Array(repeating: 4, count: EQEngine.bandCount),
            enabled: true,
            activePresetID: nil
        ))
        XCTAssertEqual(settings.activePresetID, EQPreset.flat.id)
        XCTAssertEqual(settings.bands, EQPreset.flat.floatGains)
    }

    func testSerializationRoundTrip() throws {
        let settings = EQSettings(
            bands: [-12, -6, -3, 0, 1, 2, 3, 4, 5, 12],
            enabled: true,
            activePresetID: EQPreset.spoken.id
        )
        let data = try XCTUnwrap(store.encodedPayload(for: settings))
        XCTAssertEqual(store.settings(fromEncodedPayload: data), settings)
    }

    func testBypassProducesExactlyFlatBands() {
        let settings = EQSettings(
            bands: Array(repeating: 6, count: EQEngine.bandCount),
            enabled: false,
            activePresetID: EQPreset.spoken.id
        )
        XCTAssertEqual(store.effectiveBands(for: settings), EQPreset.flat.floatGains)
    }
}
