import SwiftUI
import WatchKit

/// Watch redesign §3/§5 S1–S5 — one component for every failure. It replaces the transport *in
/// place* (title and progress stay put), says what failed in plain words, offers one or two
/// actions, and shows the diagnostic code in small monospaced type so a device report can say
/// exactly which step broke. Fires a single `.failure` haptic when it appears.
struct WatchProblemCard: View {
    struct Action {
        let title: LocalizedStringKey
        var systemImage: String?
        var isPrimary = true
        var isBusy = false
        var identifier: String
        let perform: () -> Void
    }

    let systemImage: String
    let title: LocalizedStringKey
    var message: String?
    var actions: [Action] = []
    var code: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(WatchPalette.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
            if let code {
                Text(code)
                    .font(WatchTypography.code)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("watch.now.errorCode")
                    .accessibilityLabel(Text("Diagnostic code \(code)"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WatchPalette.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch.now.problem")
        .onAppear { WKInterfaceDevice.current().play(.failure) }
    }

    @ViewBuilder
    private var actionRow: some View {
        if actions.count == 2 {
            HStack(spacing: 6) {
                ForEach(actions.indices, id: \.self) { index in actionButton(actions[index]) }
            }
        } else {
            ForEach(actions.indices, id: \.self) { index in actionButton(actions[index]) }
        }
    }

    private func actionButton(_ action: Action) -> some View {
        Button(action: action.perform) {
            if action.isBusy {
                ProgressView()
            } else if let image = action.systemImage {
                Label(action.title, systemImage: image)
            } else {
                Text(action.title)
            }
        }
        .buttonStyle(action.isPrimary ? WatchPillButtonStyle(kind: .primary, small: true)
                                      : WatchPillButtonStyle(kind: .secondary, small: true))
        .disabled(action.isBusy)
        .accessibilityIdentifier(action.identifier)
    }
}
