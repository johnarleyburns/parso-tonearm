import Testing
@testable import TonearmCore

@Suite struct IACoverPickerTests {

    private func iaFile(_ name: String, format: String? = nil,
                        source: String? = nil, original: String? = nil) -> IAFile {
        IAFile(name: name, format: format, source: source, original: original,
               length: nil, size: nil, title: nil, track: nil, album: nil,
               artist: nil, bitrate: nil, height: nil)
    }

    // MARK: - Failing Items

    @Test func testTribalMember1_thumbAndSpectrograms_returnsNil() {
        let files: [IAFile] = [
            iaFile("__ia_thumb.jpg", format: "Thumbnail", source: "original"),
            iaFile("CCRT-077-SP_spectrogram.png", format: "Spectrogram", source: "derivative"),
            iaFile("CCRT-077-SP_waveform.png", format: "Waveform", source: "derivative"),
        ]
        #expect(IACoverPicker.pickCoverFilename(files: files) == nil)
    }

    @Test func testTribalMember2_realCoverJpg_returnsCoverJpg() {
        let files: [IAFile] = [
            iaFile("cover.jpg", format: "JPEG", source: "original"),
        ]
        #expect(IACoverPicker.pickCoverFilename(files: files) == "cover.jpg")
    }

    @Test func testGregorianLP_itemImage_returnsItemImage() {
        let files: [IAFile] = [
            iaFile("lp_busto-arsizio_itemimage.png", format: "Item Image", source: "original"),
            iaFile("lp_busto-arsizio_spectrogram.png", format: "Spectrogram", source: "derivative"),
        ]
        #expect(IACoverPicker.pickCoverFilename(files: files) ==
                       "lp_busto-arsizio_itemimage.png")
    }

    @Test func testThumbOnly_noWaveforms_returnsThumb() {
        let files: [IAFile] = [
            iaFile("__ia_thumb.jpg", format: "Thumbnail", source: "original"),
        ]
        #expect(IACoverPicker.pickCoverFilename(files: files) == "__ia_thumb.jpg")
    }

    // MARK: - Edge Cases

    @Test func testEmptyFiles_returnsNil() {
        #expect(IACoverPicker.pickCoverFilename(files: []) == nil)
    }

    @Test func testNoImageFiles_returnsNil() {
        let files: [IAFile] = [
            iaFile("track01.mp3", format: "VBR MP3", source: "original"),
            iaFile("track01.flac", format: "Flac", source: "original"),
        ]
        #expect(IACoverPicker.pickCoverFilename(files: files) == nil)
    }
}
