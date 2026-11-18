import Testing
@testable import TonearmCore

@Suite struct GenrePickerAccountToggleTests {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Ingest/GenrePickerView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The production catalogue-account checkbox must be a native Toggle with
    /// the stable identifier and no tappable-image gesture.
    @Test func testAccountCheckboxIsSemanticToggleNotTapGesture() throws {
        let src = try source()
        #expect(!src.contains(".onTapGesture"))
        #expect(src.contains("Toggle(isOn: $model.showsAccountOption)"))
        #expect(src.contains("accessibilityIdentifier(\"genre.account.optional\")"))
        #expect(!src.contains(".frame(width: 22, height: 22)"))
        #expect(src.contains("minHeight: 44"))
    }
}
