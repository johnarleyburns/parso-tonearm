import Foundation

/// Blend results for the Find tab: saved blends matching a query. Pure so the
/// matching/ordering contract is testable without SwiftUI; an empty or
/// whitespace query deterministically yields no results.
public enum FindBlendSearch {
    public enum Result: Identifiable, Sendable, Equatable {
        case saved(BlendDocument)

        public var id: String {
            switch self {
            case .saved(let blend): "saved.\(blend.id.uuidString)"
            }
        }
    }

    public static func results(query: String, saved: [BlendDocument]) -> [Result] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        func hit(_ text: String) -> Bool {
            text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return saved.filter { hit($0.title) }.map(Result.saved)
    }
}
