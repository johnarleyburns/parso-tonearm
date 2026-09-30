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
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
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
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkTertiary)
                                Spacer()
                                ProgressView().tint(Palette.accent).scaleEffect(0.7)
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
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                    Spacer()
                    if progress.isDone {
                        Text("✓ \(progress.completed) of \(progress.total)")
                            .font(Typography.caption).foregroundStyle(Palette.success)
                    } else if let msg = progress.message {
                        Text(msg)
                            .font(Typography.caption).foregroundStyle(Palette.danger)
                    } else {
                        Text("\(progress.completed) / \(progress.total)")
                            .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                            .monospacedDigit()
                    }
                }
                if !progress.isDone {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.ink.opacity(0.1))
                            Capsule().fill(Palette.accent)
                                .frame(width: geo.size.width * progress.fraction)
                        }
                    }
                    .frame(height: 5)

                    Button("Cancel") {
                        appState.cancelOffline()
                    }
                    .font(Typography.caption)
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
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                    Spacer()
                    Text("Download for offline playback")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    Image(systemName: "arrow.down.circle")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.accent)
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
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            Spacer()
            Text(value)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
