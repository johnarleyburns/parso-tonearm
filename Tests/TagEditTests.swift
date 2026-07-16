import XCTest

@testable import TonearmCore

final class TagEditTests: XCTestCase {
    func testSingleEditBuildsDiffAndUndoPlan() {
        var proposal = TagEdit.Proposal()
        proposal.assignments[.title] = .text("  New Title  ")
        proposal.assignments[.genre] = .text("Soul")
        proposal.assignments.updateValue(nil, forKey: .composer)
        let track = editableTrack(
            id: 1,
            path: "/Music/01 - Old Title.flac",
            tags: tags(title: "Old Title", genre: "Jazz", composer: "Writer"))

        let plan = TagEdit.makePlan(selection: [track], proposal: proposal)

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.issues, [])
        XCTAssertEqual(plan.operations, [
            TagEdit.Operation(
                trackID: 1,
                localPath: "/Music/01 - Old Title.flac",
                changes: [
                    TagEdit.Change(field: .title, before: .text("Old Title"), after: .text("New Title")),
                    TagEdit.Change(field: .genre, before: .text("Jazz"), after: .text("Soul")),
                    TagEdit.Change(field: .composer, before: .text("Writer"), after: nil),
                ])
        ])
        XCTAssertEqual(plan.undoOperations, [
            TagEdit.Operation(
                trackID: 1,
                localPath: "/Music/01 - Old Title.flac",
                changes: [
                    TagEdit.Change(field: .title, before: .text("New Title"), after: .text("Old Title")),
                    TagEdit.Change(field: .genre, before: .text("Soul"), after: .text("Jazz")),
                    TagEdit.Change(field: .composer, before: nil, after: .text("Writer")),
                ])
        ])
    }

    func testBulkEditsFindReplaceAndNumberFromFilename() {
        let tracks = [
            editableTrack(
                id: 1,
                path: "/Music/01 - Alpha - Blue.flac",
                tags: tags(title: "Blue (Live)", albumTitle: "Old Album", trackNumber: nil)),
            editableTrack(
                id: 2,
                path: "/Music/02 - Alpha - Red.flac",
                tags: tags(title: "Red (Live)", albumTitle: "Old Album", trackNumber: nil)),
        ]
        var proposal = TagEdit.Proposal()
        proposal.assignments[.albumTitle] = .text("New Album")
        proposal.assignments[.albumArtist] = .text("Alpha")
        proposal.replacements = [
            TagEdit.FindReplace(field: .title, find: " (live)", replacement: "", caseSensitive: false),
        ]
        proposal.numberFromFilename = true

        let plan = TagEdit.makePlan(selection: tracks, proposal: proposal)

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.issues, [])
        XCTAssertEqual(plan.operations.map(\.trackID), [1, 2])
        XCTAssertEqual(plan.operations[0].changes, [
            TagEdit.Change(field: .title, before: .text("Blue (Live)"), after: .text("Blue")),
            TagEdit.Change(field: .albumTitle, before: .text("Old Album"), after: .text("New Album")),
            TagEdit.Change(field: .albumArtist, before: nil, after: .text("Alpha")),
            TagEdit.Change(field: .trackNumber, before: nil, after: .integer(1)),
        ])
        XCTAssertEqual(plan.operations[1].changes, [
            TagEdit.Change(field: .title, before: .text("Red (Live)"), after: .text("Red")),
            TagEdit.Change(field: .albumTitle, before: .text("Old Album"), after: .text("New Album")),
            TagEdit.Change(field: .albumArtist, before: nil, after: .text("Alpha")),
            TagEdit.Change(field: .trackNumber, before: nil, after: .integer(2)),
        ])
    }

    func testConflictingValuesAcrossSelectionAreReportedAsMixed() {
        let selection = [
            editableTrack(id: 1, tags: tags(title: "A", albumTitle: "First", genre: "Ambient")),
            editableTrack(id: 2, tags: tags(title: "B", albumTitle: "Second", genre: "Ambient")),
        ]

        let summary = TagEdit.summary(for: selection)

        XCTAssertEqual(summary.states[.albumTitle], .mixed)
        XCTAssertEqual(summary.states[.genre], .value(.text("Ambient")))
        XCTAssertEqual(summary.states[.composer], .empty)
    }

    func testReadOnlyTracksBlockBulkPlanAndExposeUserFacingReason() {
        let local = editableTrack(id: 1, tags: tags(title: "Local"))
        let remote = TagEdit.EditableTrack(
            id: 2,
            tags: tags(title: "Remote"),
            filename: "remote.flac",
            writeAccess: .readOnly(reason: "Remote sources are read-only. Copy the file onto this device to edit tags."))
        var proposal = TagEdit.Proposal()
        proposal.assignments[.genre] = .text("Folk")

        let plan = TagEdit.makePlan(selection: [local, remote], proposal: proposal)

        XCTAssertFalse(plan.canApply)
        XCTAssertEqual(plan.operations, [])
        XCTAssertEqual(plan.undoOperations, [])
        XCTAssertEqual(plan.issues, [
            .readOnly(
                trackID: 2,
                reason: "Remote sources are read-only. Copy the file onto this device to edit tags.")
        ])
        XCTAssertEqual(plan.issues.first?.message,
                       "Remote sources are read-only. Copy the file onto this device to edit tags.")
    }

    func testValidationRejectsBlankTitleInvalidNumbersAndBadReplaceRules() {
        var proposal = TagEdit.Proposal()
        proposal.assignments[.title] = .text(" ")
        proposal.assignments[.trackNumber] = .integer(0)
        proposal.assignments[.year] = .integer(10_000)
        proposal.replacements = [
            TagEdit.FindReplace(field: .artist, find: "", replacement: "X"),
            TagEdit.FindReplace(field: .year, find: "2020", replacement: "2021"),
        ]
        let track = editableTrack(id: 1, tags: tags(title: "Original"))

        let plan = TagEdit.makePlan(selection: [track], proposal: proposal)

        XCTAssertFalse(plan.canApply)
        XCTAssertEqual(plan.operations, [])
        XCTAssertEqual(plan.issues, [
            .emptyFind(field: .artist),
            .nonTextFindReplace(field: .year),
            .blankTitle(trackID: 1),
            .invalidInteger(trackID: 1, field: .trackNumber, value: 0),
            .invalidYear(trackID: 1, value: 10_000),
        ])
    }

    func testNoOpDiffProducesEmptyPlan() {
        var proposal = TagEdit.Proposal()
        proposal.assignments[.title] = .text("  Same  ")
        proposal.replacements = [
            TagEdit.FindReplace(field: .genre, find: "absent", replacement: "present"),
        ]
        let track = editableTrack(id: 1, tags: tags(title: "Same", genre: "Jazz"))

        let plan = TagEdit.makePlan(selection: [track], proposal: proposal)

        XCTAssertTrue(plan.isNoOp)
        XCTAssertFalse(plan.canApply)
    }

    func testEditableTrackFromTrackRowAllowsOnlyLocalFileBackedAssets() {
        let localRow = row(id: 1, asset: Asset(
            id: 1,
            trackId: 1,
            kind: .localRef,
            bookmark: nil,
            relPath: "/Music/03 - Local.flac",
            remoteURL: nil,
            altRemoteURL: nil,
            sizeBytes: nil,
            unsupportedReason: nil))
        let remoteRow = row(id: 2, asset: Asset(
            id: 2,
            trackId: 2,
            kind: .remote,
            bookmark: nil,
            relPath: nil,
            remoteURL: "https://example.test/remote.flac",
            altRemoteURL: nil,
            sizeBytes: nil,
            unsupportedReason: nil))

        let local = TagEdit.editableTrack(from: localRow)
        let remote = TagEdit.editableTrack(from: remoteRow)

        XCTAssertEqual(local.filename, "03 - Local.flac")
        XCTAssertEqual(local.writeAccess, .localFile(path: "/Music/03 - Local.flac"))
        XCTAssertEqual(remote.filename, "remote.flac")
        XCTAssertEqual(remote.writeAccess, .readOnly(
            reason: "Remote sources are read-only. Copy the file onto this device to edit tags."))
    }

    private func editableTrack(id: Int64,
                               path: String = "/Music/track.flac",
                               tags: TagEdit.Tags) -> TagEdit.EditableTrack {
        TagEdit.EditableTrack(
            id: id,
            tags: tags,
            filename: (path as NSString).lastPathComponent,
            writeAccess: .localFile(path: path))
    }

    private func tags(title: String,
                      artist: String? = nil,
                      albumTitle: String? = nil,
                      albumArtist: String? = nil,
                      genre: String? = nil,
                      composer: String? = nil,
                      trackNumber: Int? = nil,
                      discNumber: Int? = nil,
                      year: Int? = nil) -> TagEdit.Tags {
        TagEdit.Tags(
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            albumArtist: albumArtist,
            genre: genre,
            composer: composer,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year)
    }

    private func row(id: Int64, asset: Asset?) -> TrackRow {
        let track = Track(
            id: id,
            albumId: id,
            sourceId: 1,
            title: "Track \(id)",
            trackNo: Int(id),
            discNo: 1,
            durationSec: 100,
            codec: "FLAC",
            sampleRate: 44_100,
            bitDepthOrBitrate: nil,
            sortKey: "\(id)",
            genre: "Jazz",
            composer: "Composer")
        let album = Album(
            id: id,
            sourceId: 1,
            title: "Album",
            artist: "Artist",
            albumArtist: "Album Artist",
            genre: "Soul",
            year: 1977,
            artworkId: nil)
        return TrackRow(track: track, album: album, source: nil, asset: asset)
    }
}
