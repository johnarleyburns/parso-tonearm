import Foundation

/// A single LED/state message sent to a controller. Feedback is deliberately
/// limited to the address and wire value; the CoreMIDI adapter decides how to
/// encode it for the destination endpoint.
public struct MidiFeedbackEvent: Sendable, Equatable {
    public let address: MidiAddress
    public let value: Int

    public init(address: MidiAddress, value: Int) {
        self.address = address
        self.value = value
    }
}

/// Coalesces feedback bursts per control. Workspace state can change several
/// times during one run-loop turn (or a controller can echo our own output),
/// but the hardware only needs the latest state at a modest rate.
public struct MidiFeedbackThrottler: Sendable {
    public static let defaultIntervalNanoseconds: UInt64 = 20_000_000

    private let intervalNanoseconds: UInt64
    private var lastSent: [MidiAddress: UInt64] = [:]
    private var pending: [MidiAddress: MidiFeedbackEvent] = [:]

    public init(intervalNanoseconds: UInt64 = MidiFeedbackThrottler.defaultIntervalNanoseconds) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    public mutating func submit(_ event: MidiFeedbackEvent, at now: UInt64) -> [MidiFeedbackEvent] {
        pending[event.address] = event
        guard lastSent[event.address].map({ now &- $0 >= intervalNanoseconds }) ?? true else {
            return []
        }
        return flush(address: event.address, at: now)
    }

    public mutating func flush(at now: UInt64) -> [MidiFeedbackEvent] {
        let ready = pending.keys.filter {
            lastSent[$0].map({ now &- $0 >= intervalNanoseconds }) ?? true
        }
        return ready.flatMap { flush(address: $0, at: now) }
    }

    public var isEmpty: Bool { pending.isEmpty }

    private mutating func flush(address: MidiAddress, at now: UInt64) -> [MidiFeedbackEvent] {
        guard let event = pending.removeValue(forKey: address) else { return [] }
        lastSent[address] = now
        return [event]
    }
}
