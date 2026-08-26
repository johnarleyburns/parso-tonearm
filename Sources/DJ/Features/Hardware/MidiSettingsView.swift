import SwiftUI
import UniformTypeIdentifiers

/// MIDI settings (§44.1 surface, mockup `ipad/11-midi-audio-cue.html`).
///
/// Three things a user needs: what is connected, what each control does, and a
/// way to move a mapping between devices. Deliberately plain — a mapping screen
/// is a reference table, and the interesting design work is that **learning is
/// two steps**: move the control, then confirm. A knob sends a stream of values
/// while it moves, so binding the first message seen would make a nudge
/// permanent.
public struct MidiSettingsView: View {
    @StateObject private var model: MidiSettingsModel
    @State private var isExporting = false
    @State private var isImporting = false

    public init(model: MidiSettingsModel = MidiSettingsModel()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        List {
            Section("Set up my controller") {
                if model.isRunningSetup {
                    Text(model.setupProgressText ?? "")
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("midi.setup.progress")
                    if let step = model.currentSetupStep {
                        // The step's prompt is in DJ words — the user should not
                        // need to know the app's vocabulary to map their controller.
                        Text(step.prompt)
                            .font(.body)
                            .accessibilityIdentifier("midi.setup.prompt")
                    }
                    if let captured = model.capturedAddress {
                        Text("Captured: \(captured.type.rawValue) \(captured.number) "
                             + "· channel \(captured.channel)")
                            .font(.footnote.monospaced())
                            .accessibilityIdentifier("midi.setup.captured")
                    }
                    if model.capturedResolution == .fourteenBit {
                        Picker("Control resolution", selection: Binding(
                            get: { model.capturedResolution },
                            set: { model.setCapturedResolution($0) }
                        )) {
                            Text("7-bit").tag(MidiBinding.Resolution.sevenBit)
                            Text("14-bit (MSB + LSB)").tag(MidiBinding.Resolution.fourteenBit)
                        }
                        .accessibilityIdentifier("midi.setup.resolution")
                    }
                    HStack {
                        Button("Bind & continue") { model.commitLearning() }
                            .disabled(model.capturedAddress == nil)
                            .accessibilityIdentifier("midi.setup.commit")
                        Spacer()
                        Button("Skip") { model.skipSetupStep() }
                            .accessibilityIdentifier("midi.setup.skip")
                        Spacer()
                        Button("Exit", role: .cancel) { model.endSetup() }
                            .accessibilityIdentifier("midi.setup.exit")
                    }
                    Text("Everything mapped so far is kept. You can exit any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Set up my controller") { model.startSetup() }
                        .accessibilityIdentifier("midi.setup.start")
                    Text("A guided walkthrough of the essential controls — crossfader, "
                         + "faders, transport, EQ, tempo and the jog — in about a minute. "
                         + "You can stop at any point and keep what you have mapped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Controllers") {
                if model.hardware.endpoints.isEmpty {
                    // Honest empty state: nothing is wrong, there is simply no
                    // controller. Naming the transports tells a user their
                    // Bluetooth controller has to be paired in the OS first.
                    Text("No MIDI devices. Connect a class-compliant controller over USB-C, "
                         + "or pair one over Bluetooth LE MIDI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("midi.devices.empty")
                } else {
                    ForEach(model.hardware.endpoints) { endpoint in
                        Button {
                            model.hardware.connect(endpoint)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(endpoint.name)
                                    if let manufacturer = endpoint.manufacturer {
                                        Text(manufacturer).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.hardware.connectedEndpointIDs.contains(endpoint.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .accessibilityIdentifier("midi.device.\(endpoint.id)")
                    }
                }
                if let error = model.hardware.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("midi.error")
                }
            }

            if let action = model.learningAction, !model.isRunningSetup {
                Section("Learning") {
                    Text(model.statusMessage ?? "Move a control.")
                        .font(.footnote)
                        .accessibilityIdentifier("midi.learn.prompt")
                    if let captured = model.capturedAddress {
                        Text("Captured: \(captured.type.rawValue) \(captured.number) "
                             + "· channel \(captured.channel)")
                            .font(.footnote.monospaced())
                            .accessibilityIdentifier("midi.learn.captured")
                    }
                    if model.capturedResolution == .fourteenBit {
                        Picker("Control resolution", selection: Binding(
                            get: { model.capturedResolution },
                            set: { model.setCapturedResolution($0) }
                        )) {
                            Text("7-bit").tag(MidiBinding.Resolution.sevenBit)
                            Text("14-bit (MSB + LSB)").tag(MidiBinding.Resolution.fourteenBit)
                        }
                        .accessibilityIdentifier("midi.learn.resolution")
                    }
                    HStack {
                        Button("Bind to \(action.displayName)") { model.commitLearning() }
                            .disabled(model.capturedAddress == nil)
                            .accessibilityIdentifier("midi.learn.commit")
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancelLearning() }
                            .accessibilityIdentifier("midi.learn.cancel")
                    }
                }
            }

            Section("Mappings") {
                ForEach(model.bindableActions, id: \.self) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.displayName)
                            Text(model.bindingDescription(for: action))
                                .font(.caption)
                                .foregroundStyle(model.binding(for: action) == nil
                                                 ? .secondary : .primary)
                        }
                        Spacer()
                        Button(model.binding(for: action) == nil ? "Learn" : "Re-learn") {
                            model.beginLearning(action)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("midi.learn.\(action.target)")
                    }
                }
            }

            Section("Profile") {
                Button("Export mapping…") { isExporting = true }
                    .accessibilityIdentifier("midi.export")
                Button("Import mapping…") { isImporting = true }
                    .accessibilityIdentifier("midi.import")
                if let status = model.statusMessage, model.learningAction == nil {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("MIDI")
        .onAppear { model.hardware.start() }
        .fileExporter(isPresented: $isExporting,
                      document: MappingDocument(data: (try? model.exportData()) ?? Data()),
                      contentType: .json,
                      defaultFilename: "platterhead-mapping") { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            // Security-scoped: a file chosen from another app's container is
            // unreadable without this, and the failure is silent otherwise.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                model.importProfile(from: data)
            }
        }
    }
}

/// The exported mapping file (FR-HW-2) — plain JSON, so a community can share
/// and hand-edit profiles without the app hosting anything.
private struct MappingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
