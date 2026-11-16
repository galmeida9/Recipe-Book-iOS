#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// "Save this Reel to which book?" — shared by the Share Extension (`ShareReelDestinationView`),
// a link opened in the app, and Add Recipe › Paste Instagram Link. The import is only reported as
// saved after the service confirms the job is durably queued; processing then continues on the
// server with the app closed, and the draft is reviewed later inside the chosen book.

/// Presentation for the Share Extension. Host it in the extension's view controller and call
/// `completeRequest` from `onQueued`; call `cancelRequest` from `onCancel`. Errors stay on screen.
/// Doesn't use `UIApplication.shared`, so it is extension-safe.
@MainActor
public struct ShareReelDestinationView: View {
    private let sharedText: String
    private let service: any ReelShareService
    private let onQueued: (ImportJob) -> Void
    private let onCancel: () -> Void

    /// - Parameter sharedText: the URL or text Instagram shared; the Reel link is extracted from it.
    public init(sharedText: String, service: any ReelShareService,
                onQueued: @escaping (ImportJob) -> Void, onCancel: @escaping () -> Void) {
        self.sharedText = sharedText
        self.service = service
        self.onQueued = onQueued
        self.onCancel = onCancel
    }

    public var body: some View {
        let service = service
        NavigationStack {
            Group {
                if let url = ReelLink.extract(from: sharedText) {
                    ReelDestinationForm(
                        url: url,
                        loadBooks: { try await service.shareDestinations() },
                        createBook: { try await service.createBook(name: $0) },
                        queue: { try await service.queueImport(url: url, bookID: $0) },
                        onQueued: onQueued,
                        signInMessage: "Open Recipe Book and continue with Google to import Reels. Your on-device recipes stay as they are."
                    )
                } else {
                    ContentUnavailableView {
                        Label("Not a Reel link", systemImage: "link.badge.plus")
                    } description: {
                        Text("Recipe Book can import public Instagram Reels. Share the Reel itself from Instagram.")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .tint(RecipeBookTheme.accent)
    }
}

/// Lets the user pick (or create) the destination book, then queues the import.
@MainActor
struct ReelDestinationForm: View {
    let url: URL
    var preselectedBookID: BookID?
    let loadBooks: () async throws -> [BookSummary]
    let createBook: (String) async throws -> BookSummary
    let queue: (BookID) async throws -> ImportJob
    let onQueued: (ImportJob) -> Void
    /// Shown instead of the form when the service reports `signInRequired`.
    var signInMessage = "Continue with Google to import Reels."

    @State private var state: LoadState<[BookSummary]> = .loading
    @State private var reload = 0
    @State private var selection: BookID?
    @State private var creatingName: String?
    @State private var needsSignIn = false
    @State private var submitError: String?
    @State private var submit = ActionRunner()
    @State private var create = ActionRunner()
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if needsSignIn {
                ContentUnavailableView {
                    Label("Sign in to import", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(signInMessage)
                }
            } else {
                LoadingContent(state: state, retry: { reload += 1 }) { books in
                    form(books)
                }
            }
        }
        .navigationTitle("Save Reel")
        .task(id: reload) { await load() }
    }

    private func load() async {
        do {
            let books = try await loadBooks()
            state = .loaded(books)
            if selection == nil {
                selection = books.first(where: { $0.id == preselectedBookID })?.id ?? (books.count == 1 ? books[0].id : nil)
            }
            if books.isEmpty { creatingName = "" }
        } catch RecipeBookUIError.signInRequired(_) {
            needsSignIn = true
        } catch let error where !error.isCancellation {
            state = .failed(error.localizedDescription)
        } catch {}
    }

    private func form(_ books: [BookSummary]) -> some View {
        List {
            Section {
                ReelLinkCard(url: url)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section {
                ForEach(books) { book in
                    Button { selection = book.id } label: { DestinationRow(book: book, isSelected: selection == book.id) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == book.id ? .isSelected : [])
                }
                newBookRow
            } header: {
                Text("Save to")
            } footer: {
                Text("Recipe Book reads the caption, comments and spoken audio in the background — you can close the app. The draft waits in this book until you review it; nothing is saved before that.")
            }
        }
        .bottomControlBar {
            VStack(spacing: 10) {
                if let submitError {
                    Label(submitError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Couldn’t save the Reel. \(submitError)")
                }
                RunningButton(title: submitError == nil ? "Save to Book" : "Try Again",
                              systemImage: "tray.and.arrow.down", isRunning: submit.isRunning) {
                    guard let bookID = selection else { return }
                    submitError = nil
                    submit.run {
                        do {
                            onQueued(try await queue(bookID))
                        } catch RecipeBookUIError.signInRequired(_) {
                            needsSignIn = true
                        } catch let error where !error.isCancellation {
                            submitError = error.localizedDescription
                        }
                    }
                }
                .floatingPrimaryButtonStyle()
                .controlSize(.large)
                .disabled(selection == nil || create.isRunning)
            }
        }
        .disabled(submit.isRunning)
        .errorAlert($create.errorMessage)
    }

    @ViewBuilder
    private var newBookRow: some View {
        if let name = creatingName {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(spacing: 12) {
                TextField("New book name", text: Binding(get: { creatingName ?? "" }, set: { creatingName = $0 }))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { addBook(named: trimmed) }
                if create.isRunning {
                    ProgressView()
                } else {
                    Button("Create") { addBook(named: trimmed) }
                        .buttonStyle(.borderless)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        } else {
            Button {
                creatingName = ""
            } label: {
                Label("New Book", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
            }
            .accessibilityHint("Creates a personal book to save this Reel in")
        }
    }

    private func addBook(named name: String) {
        guard !name.isEmpty else { return }
        create.run {
            do {
                let book = try await createBook(name)
                if case .loaded(var books) = state {
                    books.append(book)
                    state = .loaded(books)
                }
                selection = book.id
                creatingName = nil
            } catch RecipeBookUIError.signInRequired(_) {
                needsSignIn = true
            }
        }
    }
}

@MainActor
private struct ReelLinkCard: View {
    let url: URL

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [RecipeBookTheme.accent, RecipeBookTheme.accent.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Instagram Reel").font(.headline)
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct DestinationRow: View {
    let book: BookSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(image: book.coverImage, seed: book.id,
                       symbol: book.kind == .shared ? "person.2.fill" : "book.closed.fill")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .font(.system(.body, design: .serif).weight(.semibold))
                    .lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? RecipeBookTheme.accent : Color.secondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let recipes = book.recipeCount == 1 ? "1 recipe" : "\(book.recipeCount) recipes"
        return book.kind == .shared ? "Shared · \(recipes)" : "Personal · \(recipes)"
    }
}
#endif
