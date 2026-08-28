import SwiftUI

/// A tiny transient-message queue. One toast at a time, auto-dismissed, rendered near the **bottom**
/// of the screen (above the dock) so the status bar / Dynamic Island can't clip it. Shared so any
/// call site — a Now Playing download button, the watch-connection watcher — can post without
/// threading a binding through the view tree.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var icon: String
        var kind: Kind
        /// A toast raised for a specific job (e.g. a track download) so a later completion toast can
        /// replace it rather than stack.
        var tag: String?

        enum Kind { case progress, info, success, error }
    }

    @Published private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    func progress(_ text: String, icon: String = "arrow.down.circle", tag: String? = nil) {
        show(Toast(text: text, icon: icon, kind: .progress, tag: tag), seconds: 6)
    }

    func info(_ text: String, icon: String = "info.circle", tag: String? = nil) {
        show(Toast(text: text, icon: icon, kind: .info, tag: tag), seconds: 2.6)
    }

    func success(_ text: String, icon: String = "checkmark.circle.fill", tag: String? = nil) {
        show(Toast(text: text, icon: icon, kind: .success, tag: tag), seconds: 2.4)
    }

    func error(_ text: String, icon: String = "exclamationmark.triangle.fill", tag: String? = nil) {
        show(Toast(text: text, icon: icon, kind: .error, tag: tag), seconds: 3.2)
    }

    /// Clear a still-showing progress toast for `tag` without posting anything new.
    func clear(tag: String) {
        if current?.tag == tag { dismiss() }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    private func show(_ toast: Toast, seconds: Double) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearIfCurrent(toast.id)
        }
    }

    private func clearIfCurrent(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}
