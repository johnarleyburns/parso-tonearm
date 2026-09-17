// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../../LICENSE.

#if canImport(UIKit) && !os(watchOS)
import Foundation
import SwiftUI
import TonearmDiscovery

/// Observable backing model for the sound-index status surface (plan §10, C07).
/// It maps the persisted `IndexStatusSnapshot` (real services —
/// `IndexJobRepository.coverage`, `DiscoverySettingsStore`, `discovery_runtime`)
/// to `IndexStatusPresentation` and exposes the real scheduler controls.
///
/// The pure state → display mapping lives in `TonearmDiscovery`
/// (`IndexStatusPresentation.make`) and is unit-tested there; this class only
/// owns refresh cadence and action plumbing.
@MainActor
final class IndexStatusModel: ObservableObject {
    @Published private(set) var presentation: IndexStatusPresentation?
    @Published private(set) var snapshot: IndexStatusSnapshot?
    @Published var isBusy = false

    private let controller: DiscoveryRuntimeController
    private var pollTask: Task<Void, Never>?

    init(controller: DiscoveryRuntimeController = .shared) {
        self.controller = controller
    }

    /// Whether the compact Library banner should be shown at all.
    var showsBanner: Bool { presentation?.showsBanner ?? false }

    func refresh() async {
        guard let snap = await controller.statusSnapshot() else { return }
        snapshot = snap
        presentation = IndexStatusPresentation.make(from: snap)
    }

    /// Begin a light poll while a status view is on screen (plan §10.5:
    /// "Publish UI snapshots at most twice per second" — we poll every 2 s).
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func setPaused(_ paused: Bool) async {
        isBusy = true
        await controller.setPaused(paused)
        await refresh()
        isBusy = false
    }

    func setChargingOnly(_ on: Bool) async {
        isBusy = true
        await controller.setChargingOnly(on)
        await refresh()
        isBusy = false
    }

    func setRemoteIndexingEnabled(_ on: Bool) async {
        isBusy = true
        await controller.setRemoteIndexingEnabled(on)
        await refresh()
        isBusy = false
    }

    func setRemoteIndexingWiFiOnly(_ on: Bool) async {
        isBusy = true
        await controller.setRemoteIndexingWiFiOnly(on)
        await refresh()
        isBusy = false
    }

    /// Real, current estimate for the "are you sure?" confirmation shown
    /// before letting the user turn off Wi-Fi-only remote sampling.
    func remoteIndexingEstimate() async -> (trackCount: Int, estimatedBytes: Int64) {
        await controller.remoteIndexingEstimate()
    }

    func retryFailed() async {
        isBusy = true
        _ = await controller.retryFailed()
        await refresh()
        isBusy = false
    }

    /// Backs the tappable detail sheet on each `countsCard` row — real track titles for the
    /// bucket the user tapped, on-device only.
    func trackSummaries(for bucket: IndexJobRepository.TrackListBucket) async
        -> [IndexJobRepository.TrackSummary]
    {
        await controller.trackSummaries(for: bucket)
    }

    func diagnosticsText() async -> String {
        guard let diag = await controller.diagnostics() else {
            return "Diagnostics unavailable."
        }
        return diag.plainText() + "\n\n" + diag.jsonString()
    }
}
#endif
