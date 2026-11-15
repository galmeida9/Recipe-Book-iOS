import UIKit
import UniformTypeIdentifiers
import RecipeBookCore

final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            do {
                let inputs = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                let providers = inputs.flatMap { $0.attachments ?? [] }
                var reel: URL?
                for provider in providers where reel == nil {
                    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        reel = try await loadURL(provider, type: UTType.url.identifier)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        reel = try await loadURL(provider, type: UTType.plainText.identifier)
                    }
                }
                guard let reel,
                      let group = Bundle.main.object(forInfoDictionaryKey: "RecipeBookAppGroup") as? String else {
                    throw APIError(status: 0, code: "invalid_share", message: "Share an Instagram Reel link.")
                }
                try SharedReelInbox(appGroup: group).enqueue(reel)
                let alert = UIAlertController(title: "Link saved", message: "Open Recipe Book to import and review this Reel.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in
                    self.extensionContext?.completeRequest(returningItems: nil)
                })
                present(alert, animated: true)
            } catch {
                let alert = UIAlertController(title: "Unable to save Reel", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    self.extensionContext?.cancelRequest(withError: error)
                })
                present(alert, animated: true)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, type: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = item as? URL {
                    continuation.resume(returning: ReelURL.canonicalize(url))
                } else if let text = item as? String {
                    do {
                        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                        let reel = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                            .compactMap { $0.url }.compactMap(ReelURL.canonicalize).first
                        continuation.resume(returning: reel)
                    } catch { continuation.resume(throwing: error) }
                } else { continuation.resume(returning: nil) }
            }
        }
    }
}
