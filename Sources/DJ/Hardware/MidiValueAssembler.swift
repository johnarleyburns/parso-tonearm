import Foundation

/// Joins the MSB (CC n) and LSB (CC n+32) halves of an opt-in 14-bit CC.
/// CoreMIDI parsing remains stateless; this small layer owns only the short
/// pairing window and can therefore be exercised without a device.
public struct MidiValueAssembler: Sendable {
    public static let defaultWindowNanoseconds: UInt64 = 30_000_000

    private struct Key: Hashable, Sendable {
        let channel: Int
        let number: Int
    }

    private struct Pending: Sendable {
        var msb: Int?
        var lsb: Int?
        var lastAt: UInt64
        var address: MidiAddress
    }

    private let windowNanoseconds: UInt64
    private var pending: [Key: Pending] = [:]

    public init(windowNanoseconds: UInt64 = MidiValueAssembler.defaultWindowNanoseconds) {
        self.windowNanoseconds = windowNanoseconds
    }

    /// Submit one parsed message. Seven-bit bindings pass straight through.
    /// A 14-bit MSB waits briefly for its LSB; an LSB before its MSB is held so
    /// out-of-order packets still assemble correctly.
    public mutating func submit(_ message: MidiMessage, profile: ControllerProfile,
                                at now: UInt64) -> [MidiMessage] {
        let expired = flush(at: now)
        guard message.address.type == .cc,
              let binding = profile.binding(for: message.address) else {
            // An LSB is addressed as n+32, while the binding is on n.
            guard message.address.type == .cc, message.address.number >= 32 else { return expired + [message] }
            let msbAddress = MidiAddress(type: .cc, channel: message.address.channel,
                                         number: message.address.number - 32)
            guard let binding = profile.binding(for: msbAddress),
                  binding.resolution == .fourteenBit else { return expired + [message] }
            return expired + submitHalf(message, address: msbAddress, isLSB: true, at: now)
        }
        guard binding.resolution == .fourteenBit,
              message.address.number <= 31 else { return expired + [message] }
        return expired + submitHalf(message, address: message.address, isLSB: false, at: now)
    }

    /// Emit timed-out MSBs as ordinary 7-bit values. Call this from the owner
    /// on the same cadence as the pairing window.
    public mutating func flush(at now: UInt64) -> [MidiMessage] {
        let expired = pending.filter { now &- $0.value.lastAt >= windowNanoseconds }
        var output: [MidiMessage] = []
        for (key, value) in expired {
            pending[key] = nil
            if let msb = value.msb {
                output.append(MidiMessage(address: value.address, value: msb))
            }
        }
        return output
    }

    /// Observe a complete CC MSB/LSB pair during learn. A pair is advertised
    /// only after both halves were actually seen; learn never guesses based on
    /// an MSB's usual 0...31 range.
    public mutating func observePair(_ message: MidiMessage, at now: UInt64) -> MidiAddress? {
        guard message.address.type == .cc else { return nil }
        _ = flush(at: now)
        let address: MidiAddress
        let isLSB: Bool
        if message.address.number <= 31 {
            address = message.address
            isLSB = false
        } else if message.address.number <= 63 {
            address = MidiAddress(type: .cc, channel: message.address.channel,
                                  number: message.address.number - 32)
            isLSB = true
        } else {
            return nil
        }
        let key = Key(channel: address.channel, number: address.number)
        var value = pending[key] ?? Pending(msb: nil, lsb: nil, lastAt: now, address: address)
        value.lastAt = now
        if isLSB { value.lsb = message.value & 127 } else { value.msb = message.value & 127 }
        guard value.msb != nil, value.lsb != nil else {
            pending[key] = value
            return nil
        }
        pending[key] = nil
        return address
    }

    private mutating func submitHalf(_ message: MidiMessage, address: MidiAddress,
                                     isLSB: Bool,
                                     at now: UInt64) -> [MidiMessage] {
        let key = Key(channel: address.channel, number: address.number)
        var value = pending[key] ?? Pending(msb: nil, lsb: nil, lastAt: now, address: address)
        value.lastAt = now
        if isLSB { value.lsb = message.value & 127 } else { value.msb = message.value & 127 }
        pending[key] = value
        guard let msb = value.msb, let lsb = value.lsb else { return [] }
        pending[key] = nil
        return [MidiMessage(address: address, value: (msb << 7) | lsb)]
    }
}
