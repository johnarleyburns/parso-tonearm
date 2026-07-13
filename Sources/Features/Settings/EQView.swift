import SwiftUI

struct EQView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var settings = EQSettingsPersistence.load()
    @State private var presets = EQSettingsPersistence.allPresets()
    @State private var presetName = ""

    private var store: EQSettingsStore {
        EQSettingsStore(presets: presets)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    bands
                    savePreset
                }
                .padding(18)
            }
            .foregroundStyle(Palette.ink)
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("10-band EQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Toggle("Bypass", isOn: Binding(
                get: { !settings.enabled },
                set: { bypassed in
                    settings.enabled = !bypassed
                    commit(settings)
                }
            ))
            .tint(Palette.brassDeep)
            .padding(.vertical, 8)

            Divider().overlay(Palette.hairline)

            Picker("Preset", selection: Binding(
                get: { settings.activePresetID ?? EQPreset.flat.id },
                set: { presetID in
                    settings = store.applyingPreset(id: presetID, to: settings)
                    commit(settings)
                }
            )) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .padding(.vertical, 8)

            if store.isModifiedFromPreset(settings) {
                Text("Modified from preset")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var bands: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<EQEngine.bandCount, id: \.self) { index in
                VStack(spacing: 8) {
                    Text(gainLabel(settings.bands[index]))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .frame(height: 14)
                        .monospacedDigit()
                    Slider(value: Binding(
                        get: { Double(settings.bands[index]) },
                        set: { value in
                            settings = store.updatingBand(at: index, to: Float(value), in: settings)
                            commit(settings)
                        }
                    ), in: Double(EQSettingsStore.minGain)...Double(EQSettingsStore.maxGain), step: 0.5)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 144, height: 28)
                    .frame(width: 30, height: 150)
                    .tint(Palette.brass)
                    Text(frequencyLabel(EQEngine.bandFrequencies[index]))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                        .frame(width: 34)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .glassSurface(cornerRadius: 18)
    }

    private var savePreset: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Preset name", text: $presetName)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Button {
                guard let preset = store.userPreset(named: presetName, settings: settings) else { return }
                EQSettingsPersistence.saveUserPreset(preset)
                presets = EQSettingsPersistence.allPresets()
                settings.activePresetID = preset.id
                presetName = ""
                commit(settings)
            } label: {
                Label("Save preset", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Palette.brassDeep, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func commit(_ next: EQSettings) {
        settings = store.normalized(next)
        player.updateEQ(settings: settings)
    }

    private func gainLabel(_ gain: Float) -> String {
        gain == 0 ? "0" : String(format: "%+.1f", gain)
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}
