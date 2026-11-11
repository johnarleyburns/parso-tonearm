import Foundation

/// Find-owned result scope state. A fresh Find screen starts on Songs; the
/// user's explicit choice is kept for the life of the state value.
public enum FindResultScopePolicy {
    public static let initialMode: LibraryBrowseMode = .songs
}

public struct FindResultScopeState: Equatable, Sendable {
    public private(set) var mode: LibraryBrowseMode

    public init() { mode = FindResultScopePolicy.initialMode }

    public mutating func select(_ candidate: LibraryBrowseMode) { mode = candidate }
}
