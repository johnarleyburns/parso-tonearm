import SwiftUI
import TonearmCore

/// The "Library Settings" section for remote sources, split out of
/// `SourceDetailView.swift`. `remoteManagementSection` is used from
/// `SourceDetailView.swift`'s `body`, so it stays `internal` (not `private`)
/// — `makeOfflineRow`/`managementRow` are used only within this file and stay
/// `private`.
extension SourceDetailView {
    var remoteManagementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library Settings")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.ink3)
                .padding(.top, 24)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                managementRow(label: "Provider", value: remoteProviderName)
                Divider().overlay(Palette.hairline)

                if let url = source.originalURL {
                    managementRow(label: "URL", value: url)
                    Divider().overlay(Palette.hairline)
                }

                if let account = appState.remoteAccountLabel(for: source) {
                    managementRow(label: "Account", value: account)
                    Divider().overlay(Palette.hairline)
                }

                if let status = appState.remoteCredentialStatus(for: source) {
                    managementRow(label: "Credentials", value: status)
                    Divider().overlay(Palette.hairline)
                }

                Button {
                    Task { await loadStats() }
                } label: {
                    Group {
                        if isLoadingStats {
                            HStack {
                                Text("Stats")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Palette.ink3)
                                Spacer()
                                ProgressView().tint(Palette.brass).scaleEffect(0.7)
                            }
                        } else if let _ = statsError {
                            managementRow(label: "Stats", value: "Tap to retry", chevron: false)
                        } else if let s = stats {
                            managementRow(label: "Stats", value: s.formattedSummary, chevron: false)
                        } else {
                            managementRow(label: "Stats", value: "Tap to load", chevron: false)
                        }
                    }
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)

                makeOfflineRow
                Divider().overlay(Palette.hairline)

                Button {
                    renameText = source.title
                    showRename = true
                } label: {
                    managementRow(label: "Display Name", value: source.title, chevron: true)
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)

                Button {
                    showCredentialEdit = true
                } label: {
                    managementRow(label: "Update Credentials", value: "Change password or token", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .glassSurface(cornerRadius: 14)
        }
        .alert("Rename Library", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await appState.renameSource(source, title: renameText) }
                }
            }
        }
        .alert("Update Credentials", isPresented: $showCredentialEdit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To update credentials, remove and re-add this library.")
        }
    }

    @ViewBuilder
    private var makeOfflineRow: some View {
        let isThisSource = source.id == appState.offlineSourceID
        let progress = appState.offlineProgress

        if let progress, isThisSource {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Make Offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                    Spacer()
                    if progress.isDone {
                        Text("✓ \(progress.completed) of \(progress.total)")
                            .font(.system(size: 12)).foregroundStyle(Palette.ok)
                    } else if let msg = progress.message {
                        Text(msg)
                            .font(.system(size: 11)).foregroundStyle(Palette.danger)
                    } else {
                        Text("\(progress.completed) / \(progress.total)")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            .monospacedDigit()
                    }
                }
                if !progress.isDone {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Palette.brass)
                                .frame(width: geo.size.width * progress.fraction)
                        }
                    }
                    .frame(height: 5)

                    Button("Cancel") {
                        appState.cancelOffline()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        } else {
            Button {
                Task { await appState.makeOffline(source: source) }
            } label: {
                HStack {
                    Text("Make Offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                    Spacer()
                    Text("Download for offline playback")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.brass)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func managementRow(label: String, value: String, chevron: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink3)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .regular, design: label == "URL" ? .monospaced : .default))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
