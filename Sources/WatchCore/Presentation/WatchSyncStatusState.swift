import Foundation
import TonearmWatchProtocol

/// Sync receipts are separate from live reachability. Background packets update
/// history and queue state, but cannot claim that the other app is reachable.
@MainActor
public final class WatchSyncStatusState: ObservableObject, WatchConnectivityObserver {
    @Published public private(set) var downloads: WatchDownloadStatusSnapshot?
    @Published public private(set) var lastCatalogSyncAt: Date?
    @Published public private(set) var lastPhoneStatusAt: Date?
    @Published public private(set) var lastAudioInstalledAt: Date?
    @Published public private(set) var lastRequestedAt: Date?
    @Published public private(set) var isSyncing = false
    @Published public private(set) var syncResult: WatchMetadataSyncResult?
    @Published public private(set) var phoneReachable = false

    public func setPhoneReachable(_ reachable: Bool) { phoneReachable = reachable }

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let latestInstallation: @Sendable () async -> Date?
    private var currentRequestID: UUID?

    public init(defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                latestInstallation: @escaping @Sendable () async -> Date? = { nil }) {
        self.defaults = defaults; self.now = now; self.latestInstallation = latestInstallation
        lastCatalogSyncAt = defaults.object(forKey: "watch.sync.lastCatalog") as? Date
        lastPhoneStatusAt = defaults.object(forKey: "watch.sync.lastStatus") as? Date
        lastAudioInstalledAt = defaults.object(forKey: "watch.sync.lastAudio") as? Date
    }

    public func didReceiveCatalogPage(_ page: WatchLibraryPage) async {
        lastCatalogSyncAt = now()
        defaults.set(lastCatalogSyncAt, forKey: "watch.sync.lastCatalog")
        completedSync(.confirmed)
        await refreshInstallationDate()
    }

    public func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async {
        await refreshInstallationDate()
    }

    public func didReceiveAudioFile(at stagedURL: URL, metadata: [String: String]) async {
        await refreshInstallationDate()
    }

    public func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async {
        downloads = snapshot
        lastPhoneStatusAt = snapshot.generatedAt ?? now()
        defaults.set(lastPhoneStatusAt, forKey: "watch.sync.lastStatus")
        completedSync(.confirmed)
    }

    @discardableResult
    public func requestedSync() -> UUID {
        let id = UUID()
        currentRequestID = id
        lastRequestedAt = now(); isSyncing = true; syncResult = nil
        return id
    }

    public func completedSync(_ result: WatchMetadataSyncResult, requestID: UUID? = nil) {
        if let requestID, requestID != currentRequestID { return }
        if result == .sent && syncResult == .confirmed { return }
        if result == .sent && syncResult == .failed(.requestTimedOut) { return }
        isSyncing = result == .sent
        syncResult = result
    }

    public func isDownloadStatusStale(at date: Date, after interval: TimeInterval = 30) -> Bool {
        guard downloads != nil, let lastPhoneStatusAt else { return false }
        return date.timeIntervalSince(lastPhoneStatusAt) > interval
    }

    public func refreshInstallationDate() async {
        guard let date = await latestInstallation() else { return }
        lastAudioInstalledAt = date
        defaults.set(date, forKey: "watch.sync.lastAudio")
    }
}
