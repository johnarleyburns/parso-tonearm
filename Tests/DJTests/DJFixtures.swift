import Foundation
import XCTest

@testable import TonearmDJ

/// Locates the `dj_v3` golden fixtures copied into the DJ test bundle under
/// `Fixtures/` (see `tools/clap-coreml/golden_frontend.py`).
enum DJFixtures {
    static func url(_ name: String, ext: String) -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        fatalError("Missing DJ fixture \(name).\(ext)")
    }

    static func floats(_ name: String) -> [Float] {
        let data = (try? Data(contentsOf: url(name, ext: "bin"))) ?? Data()
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
