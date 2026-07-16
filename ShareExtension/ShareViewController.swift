import UIKit
import UniformTypeIdentifiers
import TonearmCore

final class ShareViewController: UIViewController {
    private let messageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await handleShare() }
    }

    private func configureView() {
        view.backgroundColor = UIColor(red: 0.06, green: 0.055, blue: 0.05, alpha: 1)
        messageLabel.text = "Opening Tonearm..."
        messageLabel.textColor = .white
        messageLabel.font = .preferredFont(forTextStyle: .headline)
        messageLabel.textAlignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func handleShare() async {
        let payloads = await sharedPayloads()
        guard let archiveURL = SharePayloadResolver.archiveURL(from: payloads),
              let deepLink = TonearmDeepLink.url(for: .addSource(archiveURL)) else {
            finishWithError()
            return
        }
        openContainingApp(deepLink)
    }

    private func sharedPayloads() async -> [SharePayloadResolver.Payload] {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var payloads: [SharePayloadResolver.Payload] = []
        for provider in providers {
            payloads.append(contentsOf: await loadPayloads(from: provider))
        }
        return payloads
    }

    private func loadPayloads(from provider: NSItemProvider) async -> [SharePayloadResolver.Payload] {
        var payloads: [SharePayloadResolver.Payload] = []
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let payload = await loadURLPayload(from: provider) {
            payloads.append(payload)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let payload = await loadStringPayload(from: provider, typeIdentifier: UTType.plainText.identifier) {
            payloads.append(.text(payload))
        }
        if provider.hasItemConformingToTypeIdentifier("public.attributed-string"),
           let payload = await loadAttributedPayload(from: provider) {
            payloads.append(payload)
        }
        return payloads
    }

    private func loadURLPayload(from provider: NSItemProvider) async -> SharePayloadResolver.Payload? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: .url(url))
                } else if let url = item as? NSURL {
                    continuation.resume(returning: .url(url as URL))
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: .url(url))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadStringPayload(from provider: NSItemProvider,
                                   typeIdentifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadAttributedPayload(from provider: NSItemProvider) async -> SharePayloadResolver.Payload? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: "public.attributed-string", options: nil) { item, _ in
                if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: .attributedText(attributed.string))
                } else if let string = item as? String {
                    continuation.resume(returning: .attributedText(string))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private func openContainingApp(_ url: URL) {
        extensionContext?.open(url) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.finishWithError()
                }
            }
        }
    }

    @MainActor
    private func finishWithError() {
        let error = NSError(domain: "TonearmShareExtension",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "No archive.org URL was shared."])
        extensionContext?.cancelRequest(withError: error)
    }
}
