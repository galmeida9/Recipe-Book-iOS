import UIKit
import SwiftUI
import UniformTypeIdentifiers
import RecipeBookCore
import RecipeBookSharedAuth
import RecipeBookPresentation
import RecipeBookUI

final class ShareViewController: UIViewController {
    private var started = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { @MainActor in
            do {
                let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                var reel: URL?
                for provider in providers where reel == nil {
                    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        reel = try await loadURL(provider, type: UTType.url.identifier)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        reel = try await loadURL(provider, type: UTType.plainText.identifier)
                    }
                }
                guard let reel else { throw APIError(status: 0, code: "invalid_share", message: "Share an HTTPS Instagram Reel link.") }
                let service = ShareAPIService()
                let view = ShareReelDestinationView(sharedText: reel.absoluteString, service: service, onQueued: { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }, onCancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: CancellationError())
                })
                let host = UIHostingController(rootView: view)
                addChild(host)
                host.view.frame = self.view.bounds
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.view.addSubview(host.view)
                host.didMove(toParent: self)
            } catch {
                let alert = UIAlertController(title: "Unable to share Reel", message: error.localizedDescription, preferredStyle: .alert)
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
                else if let url = item as? URL { continuation.resume(returning: ReelURL.canonicalize(url)) }
                else if let text = item as? String {
                    do {
                        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                        continuation.resume(returning: detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                            .compactMap { $0.url }.compactMap(ReelURL.canonicalize).first)
                    } catch { continuation.resume(throwing: error) }
                } else { continuation.resume(returning: nil) }
            }
        }
    }
}

private actor ShareAPIService: ReelShareService {
    @MainActor private func client() throws -> APIClient {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "RecipeBookAPIURL") as? String,
              let url = URL(string: raw), !raw.contains("$(") else {
            throw APIError(status: 0, code: "configuration", message: "The share extension's Recipe Book API is not configured.")
        }
        let auth = try SharedGoogleSession(baseURL: url)
        guard try auth.hasSession() else { throw RecipeBookUIError.signInRequired(.importing) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        return try APIClient(baseURL: url, tokens: auth, session: URLSession(configuration: configuration))
    }
    func shareDestinations() async throws -> [BookSummary] {
        let api = try await client()
        return try await api.books().map(summary)
    }
    func createBook(name: String) async throws -> BookSummary {
        let api = try await client()
        return summary(try await api.createBook(name: name, kind: .personal))
    }
    func queueImport(url: URL, bookID: BookID) async throws -> RecipeBookPresentation.ImportJob {
        guard let destination = UUID(uuidString: bookID), let canonical = ReelURL.canonicalize(url) else {
            throw APIError(status: 0, code: "invalid_import", message: "Choose an account book and a public Instagram Reel.")
        }
        let api = try await client()
        let account = try await api.account()
        let key = try ImportRequestIdentity.key(accountID: account.id, bookID: destination, sourceURL: canonical)
        let job = try await api.importReel(url: canonical, bookId: destination, idempotencyKey: key, expectedAccountID: account.id)
        guard job.destinationBookId == destination else {
            throw APIError(status: 0, code: "destination_changed", message: "The server did not acknowledge the selected destination.")
        }
        let status: ImportStatus
        switch job.state {
        case .queued: status = .queued
        case .running: status = .processing
        case .review: status = .reviewRequired
        case .completed:
            guard let recipeID = job.recipeId, let bookID = job.bookId else {
                throw APIError(status: 0, code: "invalid_job", message: "The saved import identifiers were missing.")
            }
            status = .completed(recipeID: recipeID.uuidString.lowercased(), bookID: bookID.uuidString.lowercased())
        case .failed, .discarded:
            throw APIError(status: 409, code: "import_failed", message: job.error ?? "This import cannot be queued again automatically. Open its book in Recipe Book.")
        }
        guard let date = Self.date(job.createdAt) else {
            throw APIError(status: 0, code: "invalid_job", message: "The server returned an invalid import timestamp.")
        }
        return RecipeBookPresentation.ImportJob(id: job.id.uuidString.lowercased(), sourceURL: job.sourceURL, status: status,
            createdAt: date, titleHint: job.draft?.title, bookID: destination.uuidString.lowercased(), isUnseen: job.isUnseen ?? false)
    }
    private func summary(_ book: RecipeBookCore.Book) -> BookSummary {
        BookSummary(id: book.id.uuidString.lowercased(), name: book.name, kind: book.kind == .shared ? .shared : .personal,
            myRole: book.role == .owner ? .owner : .member, recipeCount: 0, memberCount: 0)
    }
    private static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
