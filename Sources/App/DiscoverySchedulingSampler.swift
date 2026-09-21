// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if !os(watchOS)
import Foundation
import Network
import TonearmCore
import TonearmDiscovery
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// Mirrors `_nominalSince` for the opposite direction — how long the
    /// thermal state has continuously read `.fair` or worse. Feeds
    /// `DiscoveryExecutionPolicy`'s sustained-`.fair` check, so a single
    /// instantaneous blip (the incident `DiscoveryExecutionPolicy`'s doc
    /// comment describes) isn't mistaken for real heat.
    private var _fairOrWorseSince: Date?
    /// Timestamps of thermal-triggered GPU→CPU downgrades, pruned to the
    /// trailing `DiscoveryExecutionPolicy.oscillationWindowSeconds` on every
    /// read — feeds the oscillation circuit breaker.
    private var _thermalDowngradeTimestamps: [Date] = []
    /// The most recently decided execution engine — read-only outside this
    /// type via `currentEngine`, so the status surface can show which
    /// engine is actually active without re-deciding (and thereby risking
    /// double-counting an oscillation) on every status read.
    private var _lastEngine: DiscoveryExecutionPolicy.Engine = .gpuPreferred
    private var _remoteIndexingWiFiOnlySetting = true
    /// Real current network path. Starts `true` (see the matching doc on
    /// `DiscoverySchedulingSnapshot.isOnWiFi`) until the first
    /// `NWPathMonitor` update replaces it with a genuine observation.
    private var _isOnWiFi = true

    private var didBeginObserving = false
    private var pathMonitor: NWPathMonitor?

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
            remoteIndexingWiFiOnlySetting: _remoteIndexingWiFiOnlySetting,
            isOnWiFi: _isOnWiFi,
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

        let nc = NotificationCenter.default
        let mainQueue = OperationQueue.main
        #if !os(macOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                       object: nil, queue: mainQueue) { _ in
            MainActor.assumeIsolated { SchedulingSampler.refreshBattery(on: self) }
        }
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                       object: nil, queue: mainQueue) { _ in
            MainActor.assumeIsolated { SchedulingSampler.refreshBattery(on: self) }
        }
        #endif
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                       object: nil, queue: mainQueue) { _ in
            self.setThermalState(Self.mapThermal(ProcessInfo.processInfo.thermalState))
        }
        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                       object: nil, queue: mainQueue) { _ in
            self.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        #if !os(macOS)
        // No `UIApplication.didReceiveMemoryWarningNotification` equivalent
        // on macOS (native-mac-app-plan.md §2c) — same reasoning as
        // `DiscoveryRuntimeController.observeMemoryWarnings()`.
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
        #endif

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.setOnWiFi(path.usesInterfaceType(.wifi))
        }
        monitor.start(queue: DispatchQueue(label: "guru.parso.tonearm.discovery.pathMonitor"))
        pathMonitor = monitor

        refreshAllFromSystem()
    }

    @MainActor
    private func refreshAllFromSystem() {
        #if !os(macOS)
        Self.refreshBattery(on: self)
        #endif
        setThermalState(Self.mapThermal(ProcessInfo.processInfo.thermalState))
        setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
        setPlaybackActive(AudioPlayer.shared.isPlaying)
    }

    #if !os(macOS)
    @MainActor
    private static func refreshBattery(on sampler: SchedulingSampler) {
        let device = UIDevice.current
        let level = Double(device.batteryLevel)  // -1 when unknown
        let charging = device.batteryState == .charging || device.batteryState == .full
        sampler.setBattery(level: level, charging: charging)
    }
    #endif

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
    func setRemoteIndexingWiFiOnlySetting(_ on: Bool) {
        withLock { _remoteIndexingWiFiOnlySetting = on }
    }
    func setOnWiFi(_ on: Bool) { withLock { _isOnWiFi = on } }
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
                _fairOrWorseSince = nil
            } else {
                _nominalSince = nil
                if _thermalState == .nominal || _fairOrWorseSince == nil { _fairOrWorseSince = Date() }
            }
            _thermalState = state
        }
    }

    // MARK: - Execution engine (GPU vs CPU) decision

    /// Decides, and records, which compute engine automatic indexing should
    /// use right now (`DiscoveryExecutionPolicy`). Mutating — advances the
    /// oscillation-tracking state — so this is the one call site that
    /// should drive the actual `ModelManager.ExecutionContext` a job
    /// resolves; status reads should use `currentEngine` instead so merely
    /// checking status never itself counts as a decision.
    func decideExecutionEngine() -> DiscoveryExecutionPolicy.Engine {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let fairOrWorseSeconds = _fairOrWorseSince.map { now.timeIntervalSince($0) } ?? 0
        _thermalDowngradeTimestamps.removeAll {
            now.timeIntervalSince($0) > DiscoveryExecutionPolicy.oscillationWindowSeconds
        }
        let snapshot = DiscoveryExecutionPolicy.Snapshot(
            thermalState: _thermalState,
            continuousFairOrWorseSeconds: fairOrWorseSeconds,
            isPlaybackActive: _isPlaybackActive,
            recentThermalDowngradeCount: _thermalDowngradeTimestamps.count)
        let engine = DiscoveryExecutionPolicy.decide(snapshot)
        if engine == .cpuOnly(reason: .thermalSustainedFair), _lastEngine == .gpuPreferred {
            _thermalDowngradeTimestamps.append(now)
        }
        _lastEngine = engine
        return engine
    }

    /// The most recently decided engine, for the status surface — does not
    /// itself decide or mutate oscillation state (see `decideExecutionEngine`).
    var currentEngine: DiscoveryExecutionPolicy.Engine {
        lock.lock(); defer { lock.unlock() }
        return _lastEngine
    }

    private func withLock(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        body()
    }
}
#endif
