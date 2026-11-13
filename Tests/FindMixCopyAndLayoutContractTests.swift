#if !os(watchOS)
import XCTest

final class FindMixCopyAndLayoutContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func testRenamedCopyAndStableIdentifiers() throws {
        let s = try source("Sources/Features/MyMusic/MyMusicSearchControls.swift")
        for new in ["\"BPM/Key\"", "\"Track BPM\"", "\"Camelot Key\""] {
            XCTAssertTrue(s.contains(new), new)
        }
        for old in ["\"Find Mix\"", "\"Mix BPM\"", "\"Mix Key\""] {
            XCTAssertFalse(s.contains(old), old)
        }
        for id in ["find.mode.all", "\"mymusic.mix.bpm\"", "\"mymusic.mix.key\""] {
            XCTAssertTrue(s.contains(id), id)
        }
        XCTAssertTrue(s.contains("\"find.mode.mix\""))
        for old in ["\"By Name\"", "\"By Mood\"", "\"By BPM/Key\""] {
            XCTAssertFalse(s.contains(old), old)
        }
        for label in ["\"Name\"", "\"Mood\"", "\"BPM/Key\""] {
            XCTAssertTrue(s.contains("= " + label), label)
        }
    }

    func testContentTopIsPinnedWithReservedHeight() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertTrue(find.contains(".frame(minHeight: Self.contentMinHeight, alignment: .top)"))
        let lib = try source("Sources/Features/Library/LibraryView.swift")
        XCTAssertTrue(lib.contains(".frame(minHeight: Self.contentAreaMinHeight, alignment: .top)"))
        XCTAssertFalse(lib.contains(".padding(.top, 60)"), "loading/empty must be top-pinned like results")
    }
}
#endif
