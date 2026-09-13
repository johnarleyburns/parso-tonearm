import Foundation

public struct SmartPlaylistRuleGroup: Equatable, Codable {
    public var conjunction: SmartPlaylistConjunction
    public var predicates: [SmartPlaylistPredicate]

    public init(conjunction: SmartPlaylistConjunction = .all,
         predicates: [SmartPlaylistPredicate] = []) {
        self.conjunction = conjunction
        self.predicates = predicates
    }

    public func matches(_ row: TrackRow, isRoot: Bool = false) -> Bool {
        guard !predicates.isEmpty else { return isRoot || conjunction == .all }
        switch conjunction {
        case .all:
            return predicates.allSatisfy { $0.matches(row) }
        case .any:
            return predicates.contains { $0.matches(row) }
        }
    }

    public func sql(isRoot: Bool = false, builder: inout SmartPlaylistSQLBuilder) -> String {
        guard !predicates.isEmpty else { return isRoot || conjunction == .all ? "1 = 1" : "0 = 1" }
        let separator = conjunction == .all ? " AND " : " OR "
        return predicates
            .map { "(\($0.sql(builder: &builder)))" }
            .joined(separator: separator)
    }
}

public enum SmartPlaylistConjunction: String, Codable, CaseIterable {
    case all
    case any
}

public indirect enum SmartPlaylistPredicate: Equatable, Codable {
    case rule(SmartPlaylistRule)
    case group(SmartPlaylistRuleGroup)

    public func matches(_ row: TrackRow) -> Bool {
        switch self {
        case .rule(let rule): return rule.matches(row)
        case .group(let group): return group.matches(row)
        }
    }

    public func sql(builder: inout SmartPlaylistSQLBuilder) -> String {
        switch self {
        case .rule(let rule): return rule.sql(builder: &builder)
        case .group(let group): return group.sql(builder: &builder)
        }
    }
}
