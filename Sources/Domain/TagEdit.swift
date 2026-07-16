import Foundation

public enum TagEdit {
    public struct EditableTrack: Equatable, Identifiable {
        public var id: Int64
        var tags: Tags
        var filename: String?
        var writeAccess: WriteAccess
    }

    public struct Tags: Equatable {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var genre: String?
        var composer: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?

        func value(for field: Field) -> Value? {
            switch field {
            case .title: return title.map(Value.text)
            case .artist: return artist.map(Value.text)
            case .albumTitle: return albumTitle.map(Value.text)
            case .albumArtist: return albumArtist.map(Value.text)
            case .genre: return genre.map(Value.text)
            case .composer: return composer.map(Value.text)
            case .trackNumber: return trackNumber.map(Value.integer)
            case .discNumber: return discNumber.map(Value.integer)
            case .year: return year.map(Value.integer)
            }
        }

        mutating func set(_ value: Value?, for field: Field) {
            switch field {
            case .title: title = value?.textValue
            case .artist: artist = value?.textValue
            case .albumTitle: albumTitle = value?.textValue
            case .albumArtist: albumArtist = value?.textValue
            case .genre: genre = value?.textValue
            case .composer: composer = value?.textValue
            case .trackNumber: trackNumber = value?.integerValue
            case .discNumber: discNumber = value?.integerValue
            case .year: year = value?.integerValue
            }
        }
    }

    public enum Field: String, CaseIterable, Equatable {
        case title
        case artist
        case albumTitle
        case albumArtist
        case genre
        case composer
        case trackNumber
        case discNumber
        case year

        var kind: FieldKind {
            switch self {
            case .title, .artist, .albumTitle, .albumArtist, .genre, .composer:
                return .text
            case .trackNumber, .discNumber, .year:
                return .integer
            }
        }
    }

    public enum FieldKind {
        case text
        case integer
    }

    public enum Value: Equatable {
        case text(String)
        case integer(Int)

        var textValue: String? {
            switch self {
            case .text(let value): return value
            case .integer: return nil
            }
        }

        var integerValue: Int? {
            switch self {
            case .text(let value): return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            case .integer(let value): return value
            }
        }
    }

    public enum WriteAccess: Equatable {
        case localFile(path: String)
        case readOnly(reason: String)

        var localPath: String? {
            switch self {
            case .localFile(let path): return path
            case .readOnly: return nil
            }
        }

        var readOnlyReason: String? {
            switch self {
            case .localFile: return nil
            case .readOnly(let reason): return reason
            }
        }
    }

    public struct SelectionSummary: Equatable {
        var states: [Field: FieldState]
    }

    public enum FieldState: Equatable {
        case empty
        case value(Value)
        case mixed
    }

    public struct Proposal: Equatable {
        var assignments: [Field: Value?] = [:]
        var replacements: [FindReplace] = []
        var numberFromFilename = false

        static let empty = Proposal()
    }

    public struct FindReplace: Equatable {
        var field: Field
        var find: String
        var replacement: String
        var caseSensitive: Bool = false
    }

    public struct Change: Equatable {
        var field: Field
        var before: Value?
        var after: Value?
    }

    public struct Operation: Equatable {
        var trackID: Int64
        var localPath: String
        var changes: [Change]
    }

    public struct Plan: Equatable {
        var operations: [Operation]
        var undoOperations: [Operation]
        var issues: [Issue]

        var canApply: Bool {
            !operations.isEmpty && !issues.contains(where: \.isError)
        }

        var isNoOp: Bool {
            operations.isEmpty && issues.isEmpty
        }
    }

    public enum Issue: Equatable {
        case readOnly(trackID: Int64, reason: String)
        case blankTitle(trackID: Int64)
        case invalidInteger(trackID: Int64, field: Field, value: Int)
        case invalidYear(trackID: Int64, value: Int)
        case emptyFind(field: Field)
        case nonTextFindReplace(field: Field)
        case missingFilenameNumber(trackID: Int64)

        var isError: Bool {
            switch self {
            case .missingFilenameNumber:
                return false
            case .readOnly, .blankTitle, .invalidInteger, .invalidYear,
                 .emptyFind, .nonTextFindReplace:
                return true
            }
        }

        var message: String {
            switch self {
            case .readOnly(_, let reason):
                return reason
            case .blankTitle:
                return "Title cannot be blank."
            case .invalidInteger(_, let field, _):
                return "\(field.rawValue) must be a positive number."
            case .invalidYear:
                return "Year must be between 1 and 9999."
            case .emptyFind:
                return "Find text cannot be empty."
            case .nonTextFindReplace(let field):
                return "Find and replace is not available for \(field.rawValue)."
            case .missingFilenameNumber:
                return "No leading track number was found in the filename."
            }
        }
    }

    public static func editableTrack(from row: TrackRow) -> EditableTrack {
        EditableTrack(
            id: row.id,
            tags: Tags(
                title: row.track.title,
                artist: row.artist?.name ?? row.album?.artist,
                albumTitle: row.album?.title,
                albumArtist: row.album?.albumArtist,
                genre: row.track.genre ?? row.album?.genre,
                composer: row.track.composer,
                trackNumber: row.track.trackNo,
                discNumber: row.track.discNo,
                year: row.album?.year),
            filename: filename(from: row.asset),
            writeAccess: writeAccess(for: row.asset))
    }

    public static func summary(for selection: [EditableTrack]) -> SelectionSummary {
        var states: [Field: FieldState] = [:]
        for field in Field.allCases {
            let values = selection.map { normalized($0.tags.value(for: field), field: field).value }
            let nonNil = values.compactMap { $0 }
            if nonNil.isEmpty {
                states[field] = .empty
            } else if let first = values.first, values.allSatisfy({ $0 == first }) {
                states[field] = first.map(FieldState.value) ?? .empty
            } else {
                states[field] = .mixed
            }
        }
        return SelectionSummary(states: states)
    }

    public static func diff(from before: Tags, to after: Tags) -> [Change] {
        Field.allCases.compactMap { field in
            let oldValue = normalized(before.value(for: field), field: field).value
            let newValue = normalized(after.value(for: field), field: field).value
            guard oldValue != newValue else { return nil }
            return Change(field: field, before: oldValue, after: newValue)
        }
    }

    public static func makePlan(selection: [EditableTrack], proposal: Proposal) -> Plan {
        var issues = validateProposal(proposal)
        var operations: [Operation] = []
        var undoOperations: [Operation] = []

        for track in selection {
            var draft = track.tags
            issues.append(contentsOf: apply(proposal, to: &draft, filename: track.filename, trackID: track.id))
            issues.append(contentsOf: validate(tags: draft, trackID: track.id))

            let changes = diff(from: track.tags, to: draft)
            guard !changes.isEmpty else { continue }
            guard let localPath = track.writeAccess.localPath else {
                issues.append(.readOnly(
                    trackID: track.id,
                    reason: track.writeAccess.readOnlyReason ?? readOnlyReason(for: nil)))
                continue
            }
            operations.append(Operation(trackID: track.id, localPath: localPath, changes: changes))
            undoOperations.append(Operation(
                trackID: track.id,
                localPath: localPath,
                changes: changes.map { Change(field: $0.field, before: $0.after, after: $0.before) }))
        }

        if issues.contains(where: \.isError) {
            operations = []
            undoOperations = []
        }
        return Plan(operations: operations, undoOperations: undoOperations, issues: issues)
    }

    public static func leadingTrackNumber(in filename: String) -> Int? {
        let lastComponent = (filename as NSString).lastPathComponent
        let stem = (lastComponent as NSString).deletingPathExtension
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = trimmed.startIndex
        var digits = ""
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard (1...3).contains(digits.count), let value = Int(digits) else { return nil }
        guard index < trimmed.endIndex else { return nil }
        var sawSeparator = false
        var scan = index
        while scan < trimmed.endIndex {
            let character = trimmed[scan]
            if character == " " || character == "-" || character == "." || character == "_" {
                sawSeparator = true
                scan = trimmed.index(after: scan)
            } else {
                break
            }
        }
        return sawSeparator ? value : nil
    }

    private static func apply(_ proposal: Proposal,
                              to draft: inout Tags,
                              filename: String?,
                              trackID: Int64) -> [Issue] {
        var issues: [Issue] = []
        for field in Field.allCases {
            guard proposal.assignments.keys.contains(field) else { continue }
            let assigned = proposal.assignments[field] ?? nil
            draft.set(normalized(assigned, field: field).value, for: field)
        }

        for replacement in proposal.replacements {
            guard replacement.field.kind == .text else { continue }
            guard let current = draft.value(for: replacement.field)?.textValue else { continue }
            let edited = replacing(
                replacement.find,
                with: replacement.replacement,
                in: current,
                caseSensitive: replacement.caseSensitive)
            draft.set(.text(edited), for: replacement.field)
        }

        if proposal.numberFromFilename {
            if let filename, let number = leadingTrackNumber(in: filename) {
                draft.trackNumber = number
            } else {
                issues.append(.missingFilenameNumber(trackID: trackID))
            }
        }
        return issues
    }

    private static func validateProposal(_ proposal: Proposal) -> [Issue] {
        var issues: [Issue] = []
        for replacement in proposal.replacements {
            if replacement.find.isEmpty {
                issues.append(.emptyFind(field: replacement.field))
            }
            if replacement.field.kind != .text {
                issues.append(.nonTextFindReplace(field: replacement.field))
            }
        }
        return issues
    }

    private static func validate(tags: Tags, trackID: Int64) -> [Issue] {
        var issues: [Issue] = []
        if normalized(tags.value(for: .title), field: .title).value == nil {
            issues.append(.blankTitle(trackID: trackID))
        }
        for field in [Field.trackNumber, .discNumber] {
            if let value = tags.value(for: field)?.integerValue, value < 1 {
                issues.append(.invalidInteger(trackID: trackID, field: field, value: value))
            }
        }
        if let year = tags.year, !(1...9999).contains(year) {
            issues.append(.invalidYear(trackID: trackID, value: year))
        }
        return issues
    }

    private static func normalized(_ value: Value?, field: Field) -> (value: Value?, wasBlank: Bool) {
        guard let value else { return (nil, false) }
        switch field.kind {
        case .text:
            guard let text = value.textValue else { return (nil, false) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : .text(trimmed), trimmed.isEmpty)
        case .integer:
            guard let integer = value.integerValue else { return (nil, false) }
            return (.integer(integer), false)
        }
    }

    private static func replacing(_ needle: String,
                                  with replacement: String,
                                  in haystack: String,
                                  caseSensitive: Bool) -> String {
        guard !needle.isEmpty else { return haystack }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return haystack.replacingOccurrences(of: needle, with: replacement, options: options)
    }

    private static func filename(from asset: Asset?) -> String? {
        for value in [asset?.relPath, asset?.remoteURL, asset?.altRemoteURL] {
            guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if let url = URL(string: raw), !url.lastPathComponent.isEmpty {
                return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            }
            let filename = URL(fileURLWithPath: raw).lastPathComponent
            if !filename.isEmpty { return filename }
        }
        return nil
    }

    private static func writeAccess(for asset: Asset?) -> WriteAccess {
        guard let asset else {
            return .readOnly(reason: readOnlyReason(for: nil))
        }
        switch asset.kind {
        case .localRef, .managedCopy:
            if let path = [asset.relPath, asset.remoteURL, asset.altRemoteURL]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return .localFile(path: path)
            }
            return .readOnly(reason: "No local file path is available for tag editing.")
        case .remote:
            return .readOnly(reason: readOnlyReason(for: .remote))
        case .builtIn:
            return .readOnly(reason: readOnlyReason(for: .builtIn))
        }
    }

    private static func readOnlyReason(for kind: AssetKind?) -> String {
        switch kind {
        case .remote:
            return "Remote sources are read-only. Copy the file onto this device to edit tags."
        case .builtIn:
            return "Built-in tracks are read-only."
        case .localRef, .managedCopy:
            return "No local file path is available for tag editing."
        case .none:
            return "No editable file is attached to this track."
        }
    }
}
