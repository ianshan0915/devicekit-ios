import UIKit
import UniformTypeIdentifiers

private enum ShareExtensionError: LocalizedError {
    case requiresSinglePDF

    var errorDescription: String? {
        switch self {
        case .requiresSinglePDF:
            "Share one PDF shipping label at a time."
        }
    }
}

final class ShareViewController: UIViewController {
    private let messageLabel = UILabel()
    private var didStart = false
    private lazy var inboxResult: Result<ShippingInbox, Error> = Result {
        try ShippingInbox()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.text = "Saving shipping label…"
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { await receivePDF() }
    }

    @MainActor
    private func receivePDF() async {
        do {
            let inbox = try inboxResult.get()
            let provider = try singlePDFProvider()
            _ = try await importPDF(from: provider, inbox: inbox)
            messageLabel.text = "Shipping label saved"
            try? await Task.sleep(nanoseconds: 350_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            messageLabel.text = error.localizedDescription
            _ = try? inboxResult.get().recordFailure(error)
            let underlyingError = error as NSError
            NSLog(
                "Shipping label import failed (domain=%@ code=%ld): %@",
                underlyingError.domain,
                underlyingError.code,
                underlyingError.localizedDescription
            )
            let extensionError = NSError(
                domain: "nl.yj-commerce.shipping-share",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
            )
            // Keep the actionable message visible briefly instead of flashing
            // back to Safari with no explanation.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            extensionContext?.cancelRequest(withError: extensionError)
        }
    }

    private func singlePDFProvider() throws -> NSItemProvider {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let pdfProviders = attachments.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }
        guard pdfProviders.count == 1, let provider = pdfProviders.first else {
            throw ShareExtensionError.requiresSinglePDF
        }
        return provider
    }

    private func importPDF(
        from provider: NSItemProvider,
        inbox: ShippingInbox
    ) async throws -> ShippingImportManifest {
        try await awaitShippingImport(timeoutSeconds: 15) { claimImport, completion in
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.pdf.identifier
            ) { url, error in
                guard claimImport() else { return }
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let url else {
                    completion(.failure(ShippingInboxError.sourceNotPDF))
                    return
                }

                do {
                    completion(.success(try inbox.importPDF(from: url)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }
}
