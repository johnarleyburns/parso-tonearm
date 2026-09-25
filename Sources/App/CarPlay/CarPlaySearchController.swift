#if !targetEnvironment(macCatalyst)
import CarPlay
import TonearmCore

/// Library search in CarPlay — iOS 27+ only (`CarPlaySearchAvailability`).
///
/// One instance per CarPlay connection, owned by `CarPlaySceneDelegate` (and
/// only created where the template is supported). It owns:
/// - the `CPSearchTemplate` delegate (`CPSearchTemplate.delegate` is weak);
/// - the Library tab's "Search" row, which it disables in place while the car
///   limits the keyboard (`CPSessionConfiguration.limitedUserInterfaces`) —
///   Apple's guidance is that the app adjusts its own entry points, and a
///   disabled row doesn't reshuffle the list under the driver's finger.
///
/// Search runs on `LibraryStore.search(_:)`, the FTS5 matcher the phone and
/// watch already use — never a second matcher. A result tap is handled only in
/// `searchTemplate(_:selectedResult:)`, the documented callback; result items
/// deliberately get no `handler` (the removed `e3ae1a5` version relied on
/// item handlers and made `selectedResult` a no-op).
@MainActor
final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
    /// CarPlay calls `updatedSearchText` per keystroke.
    private static let debounce: Duration = .milliseconds(250)
    private static let enabledDetail = "Songs, artists, albums"
    private static let limitedDetail = "Available when parked"

    private let interfaceController: CPInterfaceController
    private var hitsByItem: [ObjectIdentifier: (rows: [TrackRow], index: Int)] = [:]
    private var searchTask: Task<Void, Never>?
    private var sessionConfiguration: CPSessionConfiguration?

    /// The row `CarPlayRootBuilder` puts at the top of the Library tab.
    private(set) lazy var entryItem: CPListItem = {
        let item = CPListItem(
            text: "Search",
            detailText: Self.enabledDetail,
            image: UIImage(systemName: "magnifyingglass")
        )
        item.handler = { [weak self] _, completion in
            self?.present()
            completion()
        }
        return item
    }()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
        let configuration = CPSessionConfiguration(delegate: self)
        sessionConfiguration = configuration
        applyKeyboardLimit(configuration.limitedUserInterfaces.contains(.keyboard))
    }

    func present() {
        guard CarPlaySearchAvailability.templateSupported else { return } // never remove
        let template = CPSearchTemplate()
        template.delegate = self
        let interfaceController = interfaceController
        Task { @MainActor in
            // Only CPListTemplate may sit on top of Now Playing, and Search is
            // not a list: return to the tab bar first if Now Playing is stacked.
            if interfaceController.templates.contains(where: { $0 is CPNowPlayingTemplate }) {
                _ = try? await interfaceController.popToRootTemplate(animated: false)
            }
            _ = try? await interfaceController.pushTemplate(template, animated: true)
        }
    }

    // MARK: - CPSearchTemplateDelegate

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            hitsByItem.removeAll()
            completionHandler([])
            return
        }
        // Every call completes exactly once — including superseded ones.
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { completionHandler([]); return }
            let cap = max(1, min(CPListTemplate.maximumItemCount, 24))
            let rows = Array(((try? await LibraryStore.shared.search(query)) ?? []).prefix(cap))
            guard !Task.isCancelled else { completionHandler([]); return }
            hitsByItem.removeAll()
            let items = rows.enumerated().map { index, row -> CPListItem in
                let item = CPListItem(text: row.track.title, detailText: row.artist?.name ?? row.album?.artist)
                hitsByItem[ObjectIdentifier(item)] = (rows, index)
                return item
            }
            completionHandler(items)
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        if let hit = hitsByItem[ObjectIdentifier(item)] {
            // The result list becomes the queue, so the car's Next/Previous
            // walk the same results the driver just saw.
            AudioPlayer.shared.play(tracks: hit.rows, startAt: hit.index, source: .library)
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
        completionHandler()
    }

    // MARK: - Keyboard lockout

    fileprivate func applyKeyboardLimit(_ limited: Bool) {
        entryItem.isEnabled = !limited
        entryItem.setDetailText(limited ? Self.limitedDetail : Self.enabledDetail)
    }
}

extension CarPlaySearchController: CPSessionConfigurationDelegate {
    nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        let limited = limitedUserInterfaces.contains(.keyboard)
        Task { @MainActor in
            self.applyKeyboardLimit(limited)
        }
    }
}
#endif
