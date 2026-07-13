import XCTest
@testable import Tonearm

/// Locates Opus test fixtures copied into the test bundle under `Fixtures/`.
enum Fixtures {
    static func url(_ name: String, ext: String) -> URL {
        let bundle = Bundle(for: FixtureAnchor.self)
        if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return u
        }
        if let u = bundle.url(forResource: name, withExtension: ext) {
            return u
        }
        fatalError("Missing fixture \(name).\(ext) in test bundle")
    }

    static func data(_ name: String, ext: String) -> Data {
        (try? Data(contentsOf: url(name, ext: ext))) ?? Data()
    }
}

private final class FixtureAnchor {}
