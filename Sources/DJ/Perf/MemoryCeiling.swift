import Combine
import Darwin
import Foundation

/// §43.5 memory budget (NFR-REL-4). On macOS exceeding a memory budget makes
/// the machine slow; on iOS it makes the app *disappear* mid-set with no
/// warning. The performance-time budget is therefore a **hard limit enforced in
/// code**, not a target:
///
/// | Device class | Total RAM | App footprint ceiling while performing |
/// |---|---|---|
/// | iPhone (8 GB, A17-class) | 8 GB | **1.4 GB** |
/// | iPhone (6 GB) | 6 GB | 1.0 GB |
/// | iPad (8 GB+, M-series) | 8–16 GB | 2.0 GB |
///
/// This file is the pure policy (device class, ceiling, pressure band, shed
/// order) plus a `task_vm_info` footprint probe and a monitor that samples
/// every 2 s during a session and at every deck load. `AT-MEM-1` is the
/// user-owned on-device shipping gate (plan §2.11); its automated proxy is
/// these policy tests against fabricated samples. No `#if os` — `task_vm_info`
/// is Darwin on both iOS and macOS (the engine-core rule, §2.3).
public enum MemoryCeiling {

    /// §43.5's device classes. The 8 GB/6 GB iPhone split and the 8 GB+ iPad
    /// class are inferred from total RAM; an 8 GB iPad being classed with the
    /// 8 GB iPhone is deliberately conservative (a lower ceiling only sheds
    /// earlier, never later).
    public enum DeviceClass: Equatable, Sendable {
        case iphone8GB
        case iphone6GB
        case ipad
        case other
    }

    /// §43.5's per-class footprint ceilings.
    public static func ceilingBytes(for deviceClass: DeviceClass) -> UInt64 {
        switch deviceClass {
        case .iphone8GB: return 1_400_000_000 // 1.4 GB
        case .iphone6GB: return 1_000_000_000 // 1.0 GB
        case .ipad:      return 2_000_000_000 // 2.0 GB
        case .other:     return .max          // no hard ceiling (host / test)
        }
    }

    /// Maps total physical RAM to a §43.5 device class.
    public static func deviceClass(totalRAMBytes: UInt64) -> DeviceClass {
        switch totalRAMBytes {
        case ..<7_000_000_000:
            return .iphone6GB
        case 7_000_000_000..<9_000_000_000:
            return .iphone8GB
        case 9_000_000_000...:
            return .ipad
        default:
            return .other
        }
    }

    /// The pressure band at a given footprint, relative to the ceiling.
    ///
    /// - Under 80%: within budget.
    /// - 80–95%: **shed** in `ShedOrder`.
    /// - 95%+: **refuse the next deck load** rather than gamble.
    public enum Pressure: Equatable, Sendable {
        case underBudget
        case shedding
        case refuseLoad
    }

    public static func pressure(footprintBytes: UInt64, ceilingBytes: UInt64) -> Pressure {
        guard ceilingBytes != .max, ceilingBytes > 0 else { return .underBudget }
        let ratio = Double(footprintBytes) / Double(ceilingBytes)
        if ratio >= 0.95 { return .refuseLoad }
        if ratio >= 0.80 { return .shedding }
        return .underBudget
    }

    /// §43.5's shed order when the footprint crosses 80%: waveform LOD caches →
    /// the non-focused deck's cached stem tails → on-demand separation →
    /// analysis (already suspended during a performance, §43.2).
    public enum ShedOrder: Int, CaseIterable, Sendable {
        case waveformLODs
        case nonFocusedDeckStemTails
        case onDemandSeparation
        case analysis

        /// The normative order, low to high shed priority.
        public static let normativeOrder: [ShedOrder] = allCases
    }
}

/// The footprint read seam — a `task_vm_info.phys_footprint` probe. Tests
/// inject a fake so the pressure bands and shed decisions are deterministic
/// (plan 4.13, §2.11).
public protocol FootprintProviding: Sendable {
    /// The process's physical footprint in bytes, or `nil` if the kernel call
    /// failed (the monitor then keeps its last sample).
    func physicalFootprintBytes() -> UInt64?
}

/// Darwin `task_vm_info` physical-footprint probe. One non-blocking syscall,
/// available on iOS and macOS — no `#if os` (the engine-core rule, §2.3).
public struct TaskVMFootprintProvider: FootprintProviding {
    public init() {}

    public func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

/// The §43.5 session monitor: samples the footprint every 2 s while a session
/// is live and at every deck load, publishes the pressure band, and refuses
/// the next deck load at 95% with an honest message. Lives in `Sources/DJ/Perf/`
/// (the workspace adopts it when deck loading lands).
@MainActor
public final class MemoryCeilingMonitor: ObservableObject {

    @Published public private(set) var footprintBytes: UInt64 = 0
    @Published public private(set) var pressure: MemoryCeiling.Pressure = .underBudget

    public let deviceClass: MemoryCeiling.DeviceClass
    public let ceilingBytes: UInt64

    private let provider: any FootprintProviding
    private let sampleInterval: Duration
    private var tickTask: Task<Void, Never>?

    /// `totalRAMBytes` is injectable so tests pin the device class; production
    /// reads `ProcessInfo.processInfo.physicalMemory`.
    public init(provider: any FootprintProviding = TaskVMFootprintProvider(),
                sampleInterval: Duration = .seconds(2),
                totalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.provider = provider
        self.sampleInterval = sampleInterval
        self.deviceClass = MemoryCeiling.deviceClass(totalRAMBytes: totalRAMBytes)
        self.ceilingBytes = MemoryCeiling.ceilingBytes(for: self.deviceClass)
    }

    /// Sample now — the "every deck load" hook (§43.5). A failed probe keeps
    /// the last-known sample (a transient kernel error must not look like a
    /// drop in pressure).
    public func sampleNow() {
        guard let bytes = provider.physicalFootprintBytes() else { return }
        footprintBytes = bytes
        pressure = MemoryCeiling.pressure(footprintBytes: bytes, ceilingBytes: ceilingBytes)
    }

    /// §43.5: crossing 95% refuses the next deck load with an honest message
    /// rather than gambling. Call before loading a deck.
    public func shouldAllowDeckLoad() -> Bool {
        sampleNow()
        return pressure != .refuseLoad
    }

    /// The honest refusal message shown when `shouldAllowDeckLoad()` is false.
    public func refusalMessage() -> String {
        let percent = ceilingBytes == 0 ? 0
            : Int((Double(footprintBytes) / Double(ceilingBytes)) * 100)
        return "Memory is at \(percent)% of the safety ceiling. Close a deck or trim the crate, then load again."
    }

    /// The §43.5 shed order.
    public var shedOrder: [MemoryCeiling.ShedOrder] {
        MemoryCeiling.ShedOrder.normativeOrder
    }

    /// Start the 2 s session sampling (§43.5's "every 2 s during a session").
    /// Call when a performance begins; `stop()` when it ends.
    public func start() {
        guard tickTask == nil else { return }
        sampleNow()
        let interval = sampleInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.sampleNow()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}
