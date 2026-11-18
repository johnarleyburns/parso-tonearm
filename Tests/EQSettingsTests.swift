import Testing
@testable import TonearmCore

@Suite struct EQSettingsTests {
    private let store = EQSettingsStore()

    @Test func testClampsAtBothRails() {
        let settings = EQSettings(
            bands: [-40, -12, -6, 0, 6, 12, 40, 1, 2, 3],
            enabled: true,
            activePresetID: nil
        )
        #expect(store.normalized(settings).bands == [-12, -12, -6, 0, 6, 12, 12, 1, 2, 3])
    }

    @Test func testPresetResolution() {
        #expect(store.bands(forPresetID: EQPreset.spoken.id) == EQPreset.spoken.floatGains)
    }

    @Test func testPresetModifiedAndReselectRoundTrip() {
        var settings = store.applyingPreset(id: EQPreset.concertHall.id, to: .flat)
        #expect(!store.isModifiedFromPreset(settings))

        settings = store.updatingBand(at: 0, to: 7, in: settings)
        #expect(store.isModifiedFromPreset(settings))

        settings = store.applyingPreset(id: EQPreset.concertHall.id, to: settings)
        #expect(!store.isModifiedFromPreset(settings))
        #expect(settings.bands == EQPreset.concertHall.floatGains)
    }

    @Test func testUnknownPresetFallsBackToFlat() {
        let settings = store.applyingPreset(id: UUID(), to: EQSettings(
            bands: Array(repeating: 4, count: EQEngine.bandCount),
            enabled: true,
            activePresetID: nil
        ))
        #expect(settings.activePresetID == EQPreset.flat.id)
        #expect(settings.bands == EQPreset.flat.floatGains)
    }

    @Test func testSerializationRoundTrip() throws {
        let settings = EQSettings(
            bands: [-12, -6, -3, 0, 1, 2, 3, 4, 5, 12],
            enabled: true,
            activePresetID: EQPreset.spoken.id
        )
        let data = try #require(store.encodedPayload(for: settings))
        #expect(store.settings(fromEncodedPayload: data) == settings)
    }

    @Test func testBypassProducesExactlyFlatBands() {
        let settings = EQSettings(
            bands: Array(repeating: 6, count: EQEngine.bandCount),
            enabled: false,
            activePresetID: EQPreset.spoken.id
        )
        #expect(store.effectiveBands(for: settings) == EQPreset.flat.floatGains)
    }
}
