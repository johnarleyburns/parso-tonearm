import CoreMIDI
import Foundation

/// The CoreMIDI plumbing (§44.3, FR-HW-1) — and **only** the plumbing.
///
/// Discovery, connection and parsing live here; everything about what a message
/// *means* is in `MidiMapping`/`MidiRouter`, which are pure and tested without
/// hardware. That split is what makes controller support something the suite
/// can check: this file is a thin, boring adapter over an API that cannot be
/// faked in a unit test, and it contains no decisions.
///
/// CoreMIDI exists in full on iOS, which is why FR-HW-1 survived the platform
/// change intact. All three transports (USB-C class-compliant, Bluetooth LE
/// MIDI, Network MIDI) arrive as ordinary sources; nothing downstream cares
/// which.
@MainActor
public final class HardwareService: ObservableObject {

    /// A connectable MIDI source.
    public struct Endpoint: Sendable, Equatable, Identifiable {
        public let id: MIDIUniqueID
        public let name: String
        public let manufacturer: String?

        public init(id: MIDIUniqueID, name: String, manufacturer: String?) {
            self.id = id
            self.name = name
            self.manufacturer = manufacturer
        }
    }

    @Published public private(set) var endpoints: [Endpoint] = []
    @Published public private(set) var connectedEndpointID: MIDIUniqueID?
    /// The most recent message seen, so a learn UI can show the control the
    /// user just moved before they commit to binding it.
    @Published public private(set) var lastMessage: MidiMessage?
    /// Set while the app is waiting for the user to move a control (§44.4).
    @Published public private(set) var isLearning = false
    /// Honest failure surface: CoreMIDI refusing to start is reported, never
    /// swallowed into "no devices found", which would send the user looking at
    /// their cable.
    @Published public private(set) var lastError: String?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var started = false
    private var connectedEndpointName: String?
    private var feedbackThrottler = MidiFeedbackThrottler()
    private var feedbackFlushTask: Task<Void, Never>?

    /// Every message, for whoever is listening — the workspace binds this to
    /// the router. A stream rather than a delegate so it marshals like the
    /// session responses and telemetry already do.
    private var continuation: AsyncStream<MidiMessage>.Continuation?
    public private(set) lazy var messages: AsyncStream<MidiMessage> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    public init() {}

    deinit {
        // CoreMIDI objects are process-global; leaving a client behind on
        // teardown leaks an input port for the life of the app.
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        feedbackFlushTask?.cancel()
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Lifecycle

    /// Create the client and input port, and take a first look at what is
    /// connected. Idempotent.
    public func start() {
        guard !started else { return }
        var status = MIDIClientCreateWithBlock("guru.parso.tonearm.midi" as CFString,
                                               &client) { [weak self] notification in
            // Endpoints appearing and disappearing is a routine event — a
            // controller is plugged in mid-set more often than not.
            let messageID = notification.pointee.messageID
            guard messageID == .msgSetupChanged else { return }
            Task { @MainActor [weak self] in self?.refreshEndpoints() }
        }
        guard status == noErr else {
            lastError = "CoreMIDI could not start (OSStatus \(status))."
            return
        }
        status = MIDIInputPortCreateWithProtocol(client, "Platterhead" as CFString,
                                                 ._1_0, &inputPort) { [weak self] eventList, _ in
            // Runs on CoreMIDI's thread. Parse there (cheap, allocation-free),
            // hand the value to the main actor — never touch UI or engine state
            // from here.
            let messages = Self.parse(eventList)
            guard !messages.isEmpty else { return }
            Task { @MainActor [weak self] in
                for message in messages { self?.receive(message) }
            }
        }
        guard status == noErr else {
            lastError = "CoreMIDI input port could not be created (OSStatus \(status))."
            return
        }
        status = MIDIOutputPortCreate(client, "Platterhead output" as CFString, &outputPort)
        guard status == noErr else {
            lastError = "CoreMIDI output port could not be created (OSStatus \(status))."
            return
        }
        started = true
        refreshEndpoints()
    }

    public func refreshEndpoints() {
        var found: [Endpoint] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            found.append(Endpoint(id: Self.uniqueID(of: source),
                                  name: Self.stringProperty(source, kMIDIPropertyDisplayName)
                                      ?? Self.stringProperty(source, kMIDIPropertyName)
                                      ?? "MIDI device",
                                  manufacturer: Self.stringProperty(source, kMIDIPropertyManufacturer)))
        }
        endpoints = found
        // A controller that was connected and has gone away must not keep
        // showing as connected — the user needs to know the pads stopped
        // working because the cable came out.
        if let connected = connectedEndpointID, !found.contains(where: { $0.id == connected }) {
            connectedEndpointID = nil
        }
    }

    /// Connect to a source. Connecting to a second source does not disconnect
    /// the first — a controller plus a foot switch is an ordinary rig.
    public func connect(_ endpoint: Endpoint) {
        guard started else { return }
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard Self.uniqueID(of: source) == endpoint.id else { continue }
            let status = MIDIPortConnectSource(inputPort, source, nil)
            if status == noErr {
                connectedEndpointID = endpoint.id
                connectedEndpointName = endpoint.name
                lastError = nil
            } else {
                lastError = "Could not connect to \(endpoint.name) (OSStatus \(status))."
            }
            return
        }
    }

    // MARK: - Learn (§44.4)

    public func beginLearning() {
        isLearning = true
        lastMessage = nil
    }

    public func endLearning() {
        isLearning = false
    }

    /// Inject a message as if it had arrived from CoreMIDI. The seam the tests
    /// and the regression lane drive, since neither has a controller.
    public func receive(_ message: MidiMessage) {
        lastMessage = message
        continuation?.yield(message)
    }

    /// Send a button LED/state update to the destination belonging to the
    /// connected source. Input-only devices simply surface an honest error
    /// when feedback is requested; they do not make input or learning fail.
    public func sendFeedback(_ event: MidiFeedbackEvent) {
        let now = DispatchTime.now().uptimeNanoseconds
        let ready = feedbackThrottler.submit(event, at: now)
        ready.forEach(sendImmediately(_:))
        guard feedbackFlushTask == nil else { return }
        feedbackFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MidiFeedbackThrottler.defaultIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushFeedback()
        }
    }

    private func flushFeedback() {
        feedbackFlushTask = nil
        let now = DispatchTime.now().uptimeNanoseconds
        let ready = feedbackThrottler.flush(at: now)
        ready.forEach(sendImmediately(_:))
        if !feedbackThrottler.isEmpty {
            feedbackFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: MidiFeedbackThrottler.defaultIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                self?.flushFeedback()
            }
        }
    }

    private func sendImmediately(_ event: MidiFeedbackEvent) {
        guard outputPort != 0, let name = connectedEndpointName else {
            lastError = "MIDI feedback unavailable: no output destination is connected."
            return
        }
        var destination: MIDIEndpointRef = 0
        for index in 0..<MIDIGetNumberOfDestinations() {
            let candidate = MIDIGetDestination(index)
            guard candidate != 0 else { continue }
            let candidateName = Self.stringProperty(candidate, kMIDIPropertyDisplayName)
                ?? Self.stringProperty(candidate, kMIDIPropertyName)
            if candidateName == name {
                destination = candidate
                break
            }
        }
        guard destination != 0 else {
            lastError = "MIDI feedback unavailable: \(name) has no output destination."
            return
        }

        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        var bytes: [UInt8]
        switch event.address.type {
        case .cc:
            bytes = [0xB0 | UInt8(max(0, min(15, event.address.channel - 1))),
                     UInt8(max(0, min(127, event.address.number))),
                     UInt8(max(0, min(127, event.value)))]
        case .note:
            bytes = [0x90 | UInt8(max(0, min(15, event.address.channel - 1))),
                     UInt8(max(0, min(127, event.address.number))),
                     UInt8(max(0, min(127, event.value)))]
        case .pitchBend:
            let value = max(0, min(16383, event.value))
            bytes = [0xE0 | UInt8(max(0, min(15, event.address.channel - 1))),
                     UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
        }
        bytes.withUnsafeBufferPointer { buffer in
            _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size,
                                  packet, 0, buffer.count, buffer.baseAddress!)
        }
        let status = MIDISend(outputPort, destination, &packetList)
        if status != noErr {
            lastError = "Could not send MIDI feedback (OSStatus \(status))."
        }
    }

    // MARK: - Parsing

    /// Parse a Universal MIDI Packet list into normalised messages.
    ///
    /// Only the three message types §44.4 binds are recognised; anything else
    /// (clock, aftertouch, SysEx) is dropped here rather than travelling
    /// through the app as an unmapped event.
    nonisolated static func parse(_ eventList: UnsafePointer<MIDIEventList>) -> [MidiMessage] {
        var out: [MidiMessage] = []
        var packet = eventList.pointee.packet
        for _ in 0..<eventList.pointee.numPackets {
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < Int(packet.wordCount) && index < words.count {
                    let word = words[index]
                    let messageType = UInt8((word >> 28) & 0xF)
                    // 0x2 = MIDI 1.0 channel voice, the encoding every
                    // class-compliant controller sends.
                    guard messageType == 0x2 else { index += 1; continue }
                    let status = UInt8((word >> 20) & 0xF)
                    let channel = Int((word >> 16) & 0xF) + 1
                    let data1 = Int((word >> 8) & 0x7F)
                    let data2 = Int(word & 0x7F)
                    switch status {
                    case 0xB:
                        out.append(MidiMessage(address: MidiAddress(type: .cc, channel: channel,
                                                                    number: data1),
                                               value: data2))
                    case 0x9, 0x8:
                        // Note-off, and note-on with velocity 0, are both
                        // releases: a pad that fired on release would trigger
                        // twice per tap.
                        let value = status == 0x8 ? 0 : data2
                        out.append(MidiMessage(address: MidiAddress(type: .note, channel: channel,
                                                                    number: data1),
                                               value: value))
                    case 0xE:
                        out.append(MidiMessage(address: MidiAddress(type: .pitchBend,
                                                                    channel: channel, number: 0),
                                               value: (data2 << 7) | data1))
                    default:
                        break
                    }
                    index += 1
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        return out
    }

    private static func uniqueID(of object: MIDIObjectRef) -> MIDIUniqueID {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &id)
        return id
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
