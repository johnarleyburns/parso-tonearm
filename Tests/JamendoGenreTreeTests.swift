import XCTest
@testable import TonearmCore

/// Real report: "the Jamendo onboarding genres are much too sparse... I
/// want genres + subgenres n-levels deep essentially exposing every genre
/// category that jamendo has." `JamendoGenreTree.roots` was rebuilt from
/// live-verified Jamendo tags (see that type's doc comment for the
/// aggregation + verification methodology) — these tests are pure structural
/// invariants over the resulting tree, not a live-network check (that
/// verification already happened once, empirically, when the tree was
/// built; a unit test re-hitting the live API on every run would be flaky
/// and slow, matching this codebase's existing convention of keeping
/// pure/structural logic unit-tested and live-network behavior separate).
final class JamendoGenreTreeTests: XCTestCase {

    func testNoDuplicatePathsAcrossTheWholeTree() {
        let paths = JamendoGenreTree.all.map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count, "every node's source identity (path) must be unique")
    }

    func testTagIsAlwaysTheLastPathComponent() {
        for node in JamendoGenreTree.all {
            let expectedTag = String(node.path.split(separator: "/").last ?? Substring(node.path))
            XCTAssertEqual(node.tag, expectedTag, "\(node.path)'s tag must be its own last path segment")
        }
    }

    func testChildPathIsPrefixedByItsParentPath() {
        for parent in JamendoGenreTree.roots {
            for child in parent.children {
                XCTAssertTrue(child.path.hasPrefix("\(parent.path)/"),
                             "\(child.path) should be nested under \(parent.path)")
            }
        }
    }

    /// The specific report this fixed: "boom-bap/lo-fi/nu-jazz/dream-pop/
    /// musique-concrete return zero results" — the real cause was a
    /// spelling mismatch (Jamendo's real tags have no hyphens), not missing
    /// content. Four of five now resolve under their real spelling;
    /// "boom-bap" (no working equivalent found) was dropped rather than
    /// kept as a permanently-dead entry.
    func testPreviouslyDeadTagsNowUseTheirRealNoHyphenSpelling() {
        let tags = Set(JamendoGenreTree.all.map(\.tag))
        for realTag in ["lofi", "nujazz", "dreampop", "musiqueconcrete"] {
            XCTAssertTrue(tags.contains(realTag), "\(realTag) should be present under its real spelling")
        }
        for deadHyphenatedForm in ["lo-fi", "nu-jazz", "dream-pop", "musique-concrete", "boom-bap"] {
            XCTAssertFalse(tags.contains(deadHyphenatedForm),
                          "\(deadHyphenatedForm) was never a real Jamendo tag value")
        }
    }

    /// Real report literal ask: "essentially exposing every genre category
    /// that jamendo has" — a regression guard against the tree silently
    /// shrinking back down to its old 8-top-level/33-node size.
    func testTreeIsSubstantiallyBroaderThanThePreviousCuratedVersion() {
        XCTAssertGreaterThanOrEqual(JamendoGenreTree.roots.count, 12,
                                    "expected broad top-level coverage, not the old curated 8")
        XCTAssertGreaterThanOrEqual(JamendoGenreTree.all.count, 100,
                                    "expected genuinely deep genre+subgenre coverage")
    }

    func testEveryNodeHasANonEmptyNameAndTag() {
        for node in JamendoGenreTree.all {
            XCTAssertFalse(node.name.isEmpty)
            XCTAssertFalse(node.tag.isEmpty)
        }
    }
}
