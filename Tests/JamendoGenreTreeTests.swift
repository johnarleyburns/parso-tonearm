import Testing
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
@Suite struct JamendoGenreTreeTests {
    @Test func testGenreBrowserRetainsStableScrollAnchorsDuringPaging() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/JamendoBrowseView.swift"), encoding: .utf8)
        #expect(view.contains(".scrollPosition(id: $visibleTrackID, anchor: .top)"))
        #expect(view.contains(".scrollTargetLayout()"))
        #expect(view.contains(".id(node.id)"))
        #expect(view.contains("existingIDs.insert($0.id).inserted"), "Paging must not introduce duplicate scroll-target identities")
        #expect(view.contains("loadedGenrePath != selectedGenre.path"), "Reappearance must not reload the same genre and replace its list")
        #expect(view.contains("offset += page.count"), "Deduplicating rows must not alter the API cursor")
    }
    @Test func testMyMusicJamendoImportPolicyUsesADurableSearchSource() {
        #expect(JamendoImportPolicy.sourceIdentifier == "catalog-search")
        #expect(JamendoImportPolicy.sourceTitle == "Jamendo Search")
        #expect(JamendoImportPolicy.explanation.contains("index it"))
    }

    @Test func testNoDuplicatePathsAcrossTheWholeTree() {
        let paths = JamendoGenreTree.all.map(\.path)
        #expect(paths.count == Set(paths).count, "every node's source identity (path) must be unique")
    }

    @Test func testTagIsAlwaysTheLastPathComponent() {
        for node in JamendoGenreTree.all {
            let expectedTag = String(node.path.split(separator: "/").last ?? Substring(node.path))
            #expect(node.tag == expectedTag, "\(node.path)'s tag must be its own last path segment")
        }
    }

    @Test func testChildPathIsPrefixedByItsParentPath() {
        for parent in JamendoGenreTree.roots {
            for child in parent.children {
                #expect(child.path.hasPrefix("\(parent.path)/"),
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
    @Test func testPreviouslyDeadTagsNowUseTheirRealNoHyphenSpelling() {
        let tags = Set(JamendoGenreTree.all.map(\.tag))
        for realTag in ["lofi", "nujazz", "dreampop", "musiqueconcrete"] {
            #expect(tags.contains(realTag), "\(realTag) should be present under its real spelling")
        }
        for deadHyphenatedForm in ["lo-fi", "nu-jazz", "dream-pop", "musique-concrete", "boom-bap"] {
            #expect(!tags.contains(deadHyphenatedForm),
                          "\(deadHyphenatedForm) was never a real Jamendo tag value")
        }
    }

    /// Real report literal ask: "essentially exposing every genre category
    /// that jamendo has" — a regression guard against the tree silently
    /// shrinking back down to its old 8-top-level/33-node size.
    @Test func testTreeIsSubstantiallyBroaderThanThePreviousCuratedVersion() {
        #expect(JamendoGenreTree.roots.count >= 12,
                                    "expected broad top-level coverage, not the old curated 8")
        #expect(JamendoGenreTree.all.count >= 100,
                                    "expected genuinely deep genre+subgenre coverage")
    }

    @Test func testEveryNodeHasANonEmptyNameAndTag() {
        for node in JamendoGenreTree.all {
            #expect(!node.name.isEmpty)
            #expect(!node.tag.isEmpty)
        }
    }

    @Test func testHumanizedGenreMapsTaxonomyKeysAndPassesOthersThrough() {
        #expect(JamendoGenreTree.humanizedGenre("subgenre:electronic:progressivehouse") == "Progressive House")
        #expect(JamendoGenreTree.humanizedGenre("genre:rock") == JamendoGenreTree.roots.first { $0.path == "rock" }?.name)
        #expect(JamendoGenreTree.humanizedGenre("Classic Rock") == "Classic Rock")
        #expect(JamendoGenreTree.humanizedGenre("subgenre:nope:nope") == "subgenre:nope:nope")
    }
}
