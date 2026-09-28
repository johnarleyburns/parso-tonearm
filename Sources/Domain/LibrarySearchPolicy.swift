import Foundation

/// Scheduling rules for the catalog search field. Keeping this policy pure
/// makes the cancellation/debounce contract testable without SwiftUI.
public enum LibrarySearchPolicy {
    public static let debounce: Duration = .milliseconds(250)

    public static func shouldSearch(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
