import Foundation
import TonearmCore

/// `LibraryView`'s empty state is shared by plain My Music browsing and by Find's BPM/Key
/// modes (via `searchRows`/a non-empty `MyMusicFilter`, usually with an empty search-text
/// field). Real report: Find showed "Your music is empty" — with the add-a-library CTA — for a
/// search or BPM/Key combination that simply matched nothing, which is wrong; the library isn't
/// empty, that particular search just came up empty. Kept pure (no SwiftUI) so the distinction
/// is testable without a simulator.
public enum LibraryEmptyStatePolicy {
    public static func isUnfilteredBrowsing(
        searchText: String, searchRows: [TrackRow]?, filter: MyMusicFilter
    ) -> Bool {
        !LibrarySearchPolicy.shouldSearch(searchText) && searchRows == nil && filter.isEmpty
    }
}
