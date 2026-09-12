// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if canImport(UIKit) && !os(watchOS)
import Foundation
import TonearmCore
import TonearmDiscovery
import UIKit

/// Thread-safe cache of REAL device power/thermal/playback signals, refreshed
/// from `UIDevice`/`ProcessInfo`/`AudioPlayer` on the main actor and read
/// (synchronously, off any actor) by the `IndexScheduler`'s snapshot provider.
///
/// Every value here comes from a genuine system API — nothing is fabricated
/// (plan §6: "Do not use fake battery values ... Observe power, thermal,
/// playback and memory events"). An unreadable battery level stays `-1`
/// (mapped to `nil`/unknown, never assumed healthy).
final class SchedulingSampler: @unchecked Sendable {
    private let lock = NSLock()

    // Guarded by `lock`.
    private var _appState: DiscoveryAppRunState = .foreground
    private var _thermalState: DiscoveryThermalState = .nominal
    private var _rawBatteryLevel: Double = -1
    private var _isCharging = false
    private var _isLowPowerModeEnabled = false
    private var _isPlaybackActive = false
    private var _isUserPaused = false
    private var _chargingOnlySetting = false
    private var _hasBackgroundProcessingGrant = false
    private var _hasMemoryWarning = false
    private var _nominalSince: Date? = Date()

    private var didBeginObserving = false

    var isBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return _appState == .background
    }

    /// Called (synchronously, off-actor) by the scheduler policy each tick.
    func snapshot() -> DiscoverySchedulingSnapshot {
        lock.lock()
        let inputs = DiscoveryRawSchedulingInputs(
            appState: _appState,
            thermalState: _thermalState,
            rawBatteryLevel: _rawBatteryLevel,
            isCharging: _isCharging,
            isLowPowerModeEnabled: _isLowPowerModeEnabled,
            isPlaybackActive: _isPlaybackActive,
            isUserPaused: _isUserPaused,
            chargingOnlySetting: _chargingOnlySetting,
            hasBackgroundProcessingGrant: _hasBackgroundProcessingGrant,
            hasMemoryWarning: _hasMemoryWarning,
            isUserSelectedTrackRequest: false,
            nominalSince: _nominalSince,
            now: Date())
        lock.unlock()
        return .from(inputs)
    }

    // MARK: - Observation

    @MainActor
    func beginObserving() {
        guard !didBeginObserving else {
            refreshAllFromSystem()
            return
        }
        didBeginObserving = true

        UIDevice.current.isBatteryMonitoringEnabled = true

        let nc = NotificationCenter.default
        let mainQueue = OperationQueue.main
        nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                       object: nil, queue: mainQueue) { _ in
            MainActor.assumeIsolated { SchedulingSampler.refreshBattery(on: self) }
        }
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                       object: nil, queue: mainQueue) { _ in
            MainActor.assumeIsolated { SchedulingSampler.refreshBattery(on: self) }
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                       object: nil, queue: mainQueue) { _ in
            self.setThermalState(Self.mapThermal(ProcessInfo.processInfo.thermalState))
        }
        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                       object: nil, queue: mainQueue) { _ in
            self.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                       object: nil, queue: mainQueue) { _ in
            self.setMemoryWarning(true)
            // A memory warning is a level event; clear it after a short grace so
            // indexing can resume once buffers are released (plan §6).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                self.setMemoryWarning(false)
            }
        }

        refreshAllFromSystem()
    }

    @MainActor
    private func refreshAllFromSystem() {
        Self.refreshBattery(on: self)
        setThermalState(Self.mapThermal(ProcessInfo.processInfo.thermalState))
        setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
        setPlaybackActive(AudioPlayer.shared.isPlaying)
    }

    @MainActor
    private static func refreshBattery(on sampler: SchedulingSampler) {
        let device = UIDevice.current
        let level = Double(device.batteryLevel)  // -1 when unknown
        let charging = device.batteryState == .charging || device.batteryState == .full
        sampler.setBattery(level: level, charging: charging)
    }

    static func mapThermal(_ state: ProcessInfo.ThermalState) -> DiscoveryThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    // MARK: - Mutators (any actor)

    func setAppState(_ state: DiscoveryAppRunState) { withLock { _appState = state } }
    func setUserPaused(_ paused: Bool) { withLock { _isUserPaused = paused } }
    func setChargingOnlySetting(_ on: Bool) { withLock { _chargingOnlySetting = on } }
    func setHasBackgroundProcessingGrant(_ granted: Bool) {
        withLock { _hasBackgroundProcessingGrant = granted }
    }
    func setPlaybackActive(_ active: Bool) { withLock { _isPlaybackActive = active } }
    func setLowPowerMode(_ on: Bool) { withLock { _isLowPowerModeEnabled = on } }
    func setMemoryWarning(_ on: Bool) { withLock { _hasMemoryWarning = on } }

    func setBattery(level: Double, charging: Bool) {
        withLock {
            _rawBatteryLevel = level
            _isCharging = charging
        }
    }

    func setThermalState(_ state: DiscoveryThermalState) {
        withLock {
            if state == .nominal {
                if _thermalState != .nominal || _nominalSince == nil { _nominalSince = Date() }
            } else {
                _nominalSince = nil
            }
            _thermalState = state
        }
    }

    private func withLock(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        body()
    }
}
#endif
