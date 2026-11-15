#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// One inline import flow for every entry point (Share Sheet, Add Recipe › Paste Instagram Link,
// and resuming an unfinished job from the Library). There is no separate Imports page; the job
// lives on the server, so closing the sheet never loses progress, errors or source evidence.

/// Where the import flow starts.
public enum ReelImportStart: Equatable, Sendable {
    /// A link shared into the app; the user still confirms before anything is submitted.
    case link(URL)
    /// Add Recipe › Paste Instagram Link. Clipboard is read only via the system Paste button.
    case paste
    /// Resume an existing job (queued, processing, needs review or failed).
    case job(ImportJobID)
}

@MainActor
struct ReelImportFlowView: View {
    let start: ReelImportStart
    /// Destination chosen by starting from inside a book. `nil` = the user must pick one.
    var preselectedBookID: BookID?
    var service: (any RecipeBookService)?
    var onSubmitted: (ImportJob) -> Void = { _ in }
    var onSaved: (RecipeDetail) -> Void = { _ in }
    var onClose: () -> Void = {}

    @Environment(\.recipeBookService) private var environmentService
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case enterLink
        case confirm(URL)
        case loadingJob(ImportJobID)
        case tracking(ImportJob)
        case review(ImportJob, RecipeDraft, [BookSummary])
    }

    @State private var phase: Phase?
    @State private var text = ""
    @State private var loadError: String?
    @State private var confirmDiscard = false
    @State private var runner = ActionRunner()

    private var resolved: any RecipeBookService { service ?? environmentService }

    var body: some View {
        NavigationStack {
            Group {
                switch phase ?? initialPhase {
                case .enterLink: enterLink
                case .confirm(let url): confirm(url)
                case .loadingJob(let id): loadingJob(id)
                case .tracking(let job): tracking(job)
                case let .review(job, draft, books): review(job, draft: draft, books: books)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isReviewing {
                        Button(isSubmitted ? "Close" : "Cancel") { close() }
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning || isReviewing)
        }
        .environment(\.recipeBookService, resolved)
        .tint(RecipeBookTheme.accent)
        .errorAlert($runner.errorMessage)
    }

    private var initialPhase: Phase {
        switch start {
        case .link(let url): return .confirm(url)
        case .paste: return .enterLink
        case .job(let id): return .loadingJob(id)
        }
    }

    private var isSubmitted: Bool {
        switch phase ?? initialPhase {
        case .tracking, .review, .loadingJob: return true
        case .enterLink, .confirm: return false
        }
    }

    private var isReviewing: Bool {
        if case .review = phase ?? initialPhase { return true }
        return false
    }

    private func close() {
        runner.cancel()
        onClose()
        dismiss()
    }

    // MARK: Enter link

    private var enterLink: some View {
        let url = ReelLink.extract(from: text)
        return Form {
            Section {
                TextField("https://www.instagram.com/reel/…", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("Instagram link")
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { text = first }
                }
            } header: {
                Text("Instagram Reel link")
            } footer: {
                if !text.isEmpty && url == nil {
                    Text("That doesn’t look like a public Instagram Reel link.").foregroundStyle(.red)
                } else {
                    Text("Paste the link of a public Reel. Recipe Book only reads what you paste here.")
                }
            }
        }
        .navigationTitle("Paste Instagram Link")
        .bottomControlBar {
            Button {
                if let url { phase = .confirm(url) }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .floatingPrimaryButtonStyle()
            .controlSize(.large)
            .disabled(url == nil)
        }
    }

    // MARK: Confirm

    private func confirm(_ url: URL) -> some View {
        let valid = ReelLink.extract(from: url.absoluteString)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ImportHeroCard(systemImage: "film", title: "Import this Reel?",
                               message: valid == nil
                                   ? "This isn’t a public Instagram Reel link, so it can’t be imported."
                                   : "Recipe Book reads the Reel’s caption, comments and spoken audio to prepare a draft. You’ll check every ingredient and step before anything is saved.")
                if let valid {
                    Text(valid.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    WatchOnInstagramButton(url: valid, compact: true)
                }
            }
            .padding(20)
        }
        .navigationTitle("Import from Instagram")
        .bottomControlBar(isPresented: valid != nil) {
            RunningButton(title: "Import Reel", systemImage: "square.and.arrow.down", isRunning: runner.isRunning) {
                guard let valid else { return }
                runner.run {
                    let job = try await resolved.submitImport(url: valid)
                    onSubmitted(job)
                    phase = .tracking(job)
                }
            }
            .floatingPrimaryButtonStyle()
            .controlSize(.large)
        }
    }

    // MARK: Resume

    private func loadingJob(_ id: ImportJobID) -> some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn’t load import", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { self.loadError = nil; phase = .loadingJob(id) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Import")
        .task(id: loadError == nil ? id : "") {
            guard loadError == nil else { return }
            do {
                await advance(with: try await resolved.importJob(id: id))
            } catch let error where !error.isCancellation {
                loadError = error.localizedDescription
            } catch {}
        }
    }

    // MARK: Tracking

    private func tracking(_ job: ImportJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ImportStatusCard(job: job)
                if case .failed(_, let canRetry) = job.status {
                    VStack(spacing: 10) {
                        if canRetry {
                            RunningButton(title: "Try Again", systemImage: "arrow.clockwise", isRunning: runner.isRunning) {
                                runner.run { phase = .tracking(try await resolved.retryImport(id: job.id)) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        Button("Discard Import", role: .destructive) { confirmDiscard = true }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(runner.isRunning)
                    }
                } else if job.status.isInFlight {
                    Text("You can close this. The import keeps going and stays in your Library under “Imports in progress”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                WatchOnInstagramButton(url: job.sourceURL, compact: true)
            }
            .padding(20)
        }
        .navigationTitle("Importing")
        .task(id: job) {
            guard job.status.isInFlight || job.status == .reviewRequired else { return }
            if job.status == .reviewRequired { await advance(with: job); return }
            // Poll while the server is working. Leaving the sheet cancels polling, not the job.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                do {
                    let latest = try await resolved.importJob(id: job.id)
                    if latest != job { await advance(with: latest); return }
                } catch let error where !error.isCancellation {
                    runner.errorMessage = error.localizedDescription
                    return
                } catch { return }
            }
        }
        .confirmationDialog("Discard this import?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard(job) }
        }
    }

    private func advance(with job: ImportJob) async {
        guard job.status == .reviewRequired else { phase = .tracking(job); return }
        do {
            async let draft = resolved.importReview(id: job.id)
            async let books = resolved.books()
            var reviewDraft = try await draft
            // The destination is either the book the user started from, or chosen in review.
            reviewDraft.bookID = preselectedBookID
            phase = .review(job, reviewDraft, try await books)
        } catch let error where !error.isCancellation {
            phase = .tracking(job)
            runner.errorMessage = error.localizedDescription
        } catch {}
    }

    // MARK: Review

    private func review(_ job: ImportJob, draft: RecipeDraft, books: [BookSummary]) -> some View {
        VStack(spacing: 0) {
            let pending = draft.ingredients.filter(\.amountNeedsReview).count
            if pending > 0 {
                Label(pending == 1
                      ? "1 amount was unclear in the Reel and is left blank."
                      : "\(pending) amounts were unclear in the Reel and are left blank.",
                      systemImage: "questionmark.diamond")
                    .font(.subheadline)
                    .foregroundStyle(RecipeBookTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(RecipeBookTheme.warning.opacity(0.12))
            }
            RecipeEditorView(title: "Review Recipe", draft: draft, destinationBooks: books.filter { $0.storage == .account },
                             saveLabel: "Save Recipe", showsCancel: false) { reviewed in
                try await resolved.approveImport(id: job.id, draft: reviewed)
            } onSaved: { saved in
                onSaved(saved)
                onClose()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Later") { close() }
                    .accessibilityHint("Keeps the import for review from your Library")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Discard Import", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            }
        }
        .confirmationDialog("Discard this import?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard(job) }
        } message: {
            Text("The extracted draft and its source text will be removed.")
        }
    }

    private func discard(_ job: ImportJob) {
        runner.run {
            try await resolved.discardImport(id: job.id)
            close()
        }
    }
}

/// Kept for app-layer call sites: confirms a shared link and then continues in the same inline
/// import flow. `onFinished` receives the submitted job (acknowledge the inbox entry then), or
/// `nil` if the user cancelled before submitting.
@MainActor
public struct ReelImportConfirmView: View {
    private let url: URL
    private let service: (any RecipeBookService)?
    private let onFinished: (ImportJob?) -> Void
    @State private var submitted = false

    public init(url: URL, service: (any RecipeBookService)? = nil, onFinished: @escaping (ImportJob?) -> Void) {
        self.url = url
        self.service = service
        self.onFinished = onFinished
    }

    public var body: some View {
        ReelImportFlowView(start: .link(url), service: service,
                           onSubmitted: { job in submitted = true; onFinished(job) },
                           onClose: { if !submitted { onFinished(nil) } })
    }
}

// MARK: - Pieces

@MainActor
private struct ImportHeroCard: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(RecipeBookTheme.accent)
                .accessibilityHidden(true)
            Text(title).displayTitle(.title)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status of one job with explicit stage wording.
@MainActor
struct ImportStatusCard: View {
    let job: ImportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if job.status.isInFlight {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: job.status.systemImage)
                        .font(.title)
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.title3.weight(.semibold))
                    Text(job.titleHint ?? "Instagram Reel")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch job.status {
        case .queued: return "Waiting to start"
        case .processing: return "Reading the Reel"
        case .reviewRequired: return "Ready for review"
        case .failed: return "Import failed"
        case .completed: return "Saved"
        }
    }

    private var detail: String {
        switch job.status {
        case .queued: return "Your import is queued and will start shortly."
        case .processing: return "Collecting the caption, comments and spoken audio to draft ingredients and steps."
        case .reviewRequired: return "Check the draft and choose a book."
        case .failed(let reason, _): return reason
        case .completed: return "This recipe is already in your Library."
        }
    }

    private var color: Color {
        switch job.status {
        case .failed: return .red
        case .completed: return RecipeBookTheme.success
        default: return RecipeBookTheme.accent
        }
    }
}

@MainActor
struct ImportJobRow: View {
    let job: ImportJob

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(RecipeBookTheme.accent.opacity(0.12))
                if job.status.isInFlight {
                    ProgressView()
                } else {
                    Image(systemName: job.status.systemImage).foregroundStyle(color)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.titleHint ?? "Instagram Reel")
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(job.status.title).foregroundStyle(color)
                    Text("·")
                    Text(job.createdAt, style: .relative)
                }
                .font(.caption)
                if case .failed(let reason, _) = job.status {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch job.status {
        case .reviewRequired: return RecipeBookTheme.accent
        case .failed: return .red
        case .completed: return RecipeBookTheme.success
        case .queued, .processing: return .secondary
        }
    }
}

/// Opens the original Reel with the system URL handler (Instagram app via universal link when
/// installed, otherwise the browser). Only validated canonical Instagram Reel links are shown.
@MainActor
struct WatchOnInstagramButton: View {
    let url: URL?
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let watch = ReelLink.watchURL(for: url) {
            Button {
                openURL(watch)
            } label: {
                Label("Watch on Instagram", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: compact ? nil : .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .regular : .large)
            .accessibilityHint("Opens the original Reel in Instagram or your browser")
        }
    }
}
#endif
