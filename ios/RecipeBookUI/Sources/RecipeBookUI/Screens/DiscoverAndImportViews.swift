#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// MARK: - Suggestions

/// "What can I cook?" — suggestions come only from saved recipes the user can access.
@MainActor
struct SuggestionsView: View {
    @Environment(\.recipeBookService) private var service
    @State private var input = ""
    @State private var haves: [String] = []
    @State private var submitted: [String]?
    @State private var searchToken = 0
    @State private var results: LoadState<[RecipeSuggestion]> = .loading
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add an ingredient you have", text: $input)
                            .focused($inputFocused)
                            .submitLabel(.done)
                            .onSubmit(addInput)
                        Button("Add", action: addInput)
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !haves.isEmpty {
                        FlowChips(items: haves) { item in haves.removeAll { $0 == item } }
                    }
                    Button {
                        inputFocused = false
                        submitted = haves
                        searchToken += 1
                    } label: {
                        Label("Find Recipes", systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(haves.isEmpty)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("I have")
                } footer: {
                    Text("Suggestions come only from recipes saved in your books.")
                }

                if submitted != nil {
                    resultsSection
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("What can I cook?", systemImage: "frying.pan")
                        } description: {
                            Text("Add a few ingredients you have and we’ll match them against your saved recipes.")
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Cook")
            .recipeDestinations()
        }
        .task(id: searchToken) {
            guard let query = submitted else { return }
            results = .loading
            do {
                results = .loaded(try await service.suggestions(have: query))
            } catch let error where !error.isCancellation {
                results = .failed(error.localizedDescription)
            } catch {}
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        switch results {
        case .loading:
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Try Again") { searchToken += 1 }
            }
        case .loaded(let suggestions) where suggestions.isEmpty:
            Section {
                ContentUnavailableView("No matches",
                                       systemImage: "fork.knife",
                                       description: Text("None of your saved recipes use these ingredients yet."))
            }
        case .loaded(let suggestions):
            Section("Suggestions") {
                ForEach(suggestions) { suggestion in
                    NavigationLink(value: RecipeRoute(id: suggestion.recipe.id, title: suggestion.recipe.title)) {
                        SuggestionRow(suggestion: suggestion)
                    }
                }
            }
        }
    }

    private func addInput() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !haves.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            haves.append(value)
        }
        input = ""
    }
}

@MainActor
private struct SuggestionRow: View {
    let suggestion: RecipeSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.recipe.title)
                .font(.system(.body, design: .serif).weight(.medium))
            Text(suggestion.bookName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !suggestion.matchedIngredients.isEmpty {
                Label("Uses " + suggestion.matchedIngredients.joined(separator: ", "), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(RecipeBookTheme.success)
            }
            if !suggestion.missingIngredients.isEmpty {
                Label("Also needs " + suggestion.missingIngredients.joined(separator: ", "), systemImage: "cart")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Removable ingredient chips that wrap across lines.
@MainActor
struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    onRemove(item)
                } label: {
                    HStack(spacing: 4) {
                        Text(item)
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(RecipeBookTheme.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Imports

@MainActor
struct ImportsView: View {
    @Environment(\.recipeBookService) private var service
    @State private var state: LoadState<[ImportJob]> = .loading
    @State private var reload = 0
    @State private var showingPaste = false
    @State private var runner = ActionRunner()

    private var hasInFlight: Bool { state.value?.contains { $0.status.isInFlight } ?? false }

    var body: some View {
        NavigationStack {
            LoadingContent(state: state, retry: { reload += 1 }) { jobs in
                if jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No imports yet", systemImage: "film.stack")
                    } description: {
                        Text("Share a public Instagram Reel to Recipe Book, or paste its link. You’ll review the recipe before it’s saved.")
                    } actions: {
                        Button("Paste Reel Link") { showingPaste = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list(jobs)
                }
            }
            .navigationTitle("Imports")
            .toolbar {
                Button { showingPaste = true } label: { Label("Paste Reel Link", systemImage: "link.badge.plus") }
            }
            .recipeDestinations()
            .navigationDestination(for: ImportReviewRoute.self) { ImportReviewView(jobID: $0.id) { reload += 1 } }
            .sheet(isPresented: $showingPaste) {
                PasteReelSheet { _ in reload += 1 }
            }
        }
        .task(id: reload) {
            await load()
            // Poll while the server is still working on queued/processing jobs.
            while !Task.isCancelled && hasInFlight {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        .errorAlert($runner.errorMessage)
    }

    private struct JobGroup: Identifiable {
        let id: String
        let jobs: [ImportJob]
    }

    private func list(_ jobs: [ImportJob]) -> some View {
        let groups = [
            JobGroup(id: "Needs review", jobs: jobs.filter { $0.status == .reviewRequired }),
            JobGroup(id: "In progress", jobs: jobs.filter { $0.status.isInFlight }),
            JobGroup(id: "Failed", jobs: jobs.filter { if case .failed = $0.status { return true } else { return false } }),
            JobGroup(id: "Saved", jobs: jobs.filter { if case .completed = $0.status { return true } else { return false } }),
        ]
        return List {
            ForEach(groups) { group in
                if !group.jobs.isEmpty {
                    Section(group.id) {
                        ForEach(group.jobs) { job in row(job) }
                    }
                }
            }
        }
        .refreshable { await load() }
        .disabled(runner.isRunning)
    }

    @ViewBuilder
    private func row(_ job: ImportJob) -> some View {
        switch job.status {
        case .reviewRequired:
            NavigationLink(value: ImportReviewRoute(id: job.id)) { ImportJobRow(job: job) }
                .swipeActions { discardButton(job) }
        case .completed(let recipeID, _):
            NavigationLink(value: RecipeRoute(id: recipeID, title: job.titleHint ?? "Recipe")) { ImportJobRow(job: job) }
        case .failed(_, let canRetry):
            ImportJobRow(job: job)
                .swipeActions {
                    discardButton(job)
                    if canRetry {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            runner.run { _ = try await service.retryImport(id: job.id); reload += 1 }
                        }
                        .tint(RecipeBookTheme.accent)
                    }
                }
                .contextMenu {
                    if canRetry {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            runner.run { _ = try await service.retryImport(id: job.id); reload += 1 }
                        }
                    }
                    discardButton(job)
                }
        case .queued, .processing:
            ImportJobRow(job: job)
        }
    }

    private func discardButton(_ job: ImportJob) -> some View {
        Button("Discard", systemImage: "trash", role: .destructive) {
            runner.run { try await service.discardImport(id: job.id); reload += 1 }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await service.importJobs())
        } catch let error where !error.isCancellation {
            if state.value == nil {
                state = .failed(error.localizedDescription)
            } else {
                runner.errorMessage = error.localizedDescription
            }
        } catch {}
    }
}

struct ImportReviewRoute: Hashable {
    let id: ImportJobID
}

@MainActor
struct ImportJobRow: View {
    let job: ImportJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if job.status.isInFlight {
                    ProgressView()
                } else {
                    Image(systemName: job.status.systemImage)
                        .foregroundStyle(color)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.titleHint ?? "Instagram Reel")
                    .font(.body.weight(.medium))
                Text(job.sourceURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(job.status.title).foregroundStyle(color)
                    Text("·")
                    Text(job.createdAt, style: .relative)
                }
                .font(.caption)
                if case .failed(let reason, _) = job.status {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
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

/// Paste a Reel link manually.
@MainActor
struct PasteReelSheet: View {
    let onSubmitted: (ImportJob) -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var runner = ActionRunner()

    private var url: URL? { ReelLink.extract(from: text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.instagram.com/reel/…", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                } header: {
                    Text("Reel link")
                } footer: {
                    if !text.isEmpty && url == nil {
                        Text("That doesn’t look like a public Instagram Reel link.").foregroundStyle(.red)
                    } else {
                        Text("Only public Reels can be imported. Nothing is saved until you review it.")
                    }
                }
                if let url {
                    Section("Will import") {
                        Text(url.absoluteString).font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle("Import from Reel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Import") {
                            guard let url else { return }
                            runner.run {
                                let job = try await service.submitImport(url: url)
                                onSubmitted(job)
                                dismiss()
                            }
                        }
                        .disabled(url == nil)
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .errorAlert($runner.errorMessage)
    }
}

/// Confirmation shown when a Reel link is shared into the app. Never submits without a tap.
@MainActor
public struct ReelImportConfirmView: View {
    private let url: URL
    private let service: (any RecipeBookService)?
    private let onFinished: (ImportJob?) -> Void
    @Environment(\.recipeBookService) private var environmentService
    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()

    /// - Parameters:
    ///   - service: Pass when used outside `RecipeBookRootView`; otherwise the injected service is used.
    ///   - onFinished: Called with the created job, or `nil` if the user cancelled.
    public init(url: URL, service: (any RecipeBookService)? = nil, onFinished: @escaping (ImportJob?) -> Void) {
        self.url = url
        self.service = service
        self.onFinished = onFinished
    }

    private var validURL: URL? { ReelLink.extract(from: url.absoluteString) }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "film")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(RecipeBookTheme.accent)
                    .accessibilityHidden(true)
                Text("Import this Reel?").displayTitle(.title)
                if let validURL {
                    Text(validURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Recipe Book will read the public Reel and prepare a draft. You’ll check ingredients and choose a book before anything is saved.")
                        .foregroundStyle(.secondary)
                } else {
                    Label("This isn’t a public Instagram Reel link, so it can’t be imported.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(RecipeBookTheme.warning)
                }
                Spacer()
                if let validURL {
                    RunningButton(title: "Import Reel", isRunning: runner.isRunning) {
                        let service = service ?? environmentService
                        runner.run {
                            let job = try await service.submitImport(url: validURL)
                            onFinished(job)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        runner.cancel()
                        onFinished(nil)
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .tint(RecipeBookTheme.accent)
        .errorAlert($runner.errorMessage)
    }
}

/// Review an extracted draft, choose the destination book explicitly, then save.
@MainActor
struct ImportReviewView: View {
    let jobID: ImportJobID
    let onDone: () -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<(RecipeDraft, [BookSummary])> = .loading
    @State private var reload = 0
    @State private var confirmDiscard = false
    @State private var runner = ActionRunner()

    var body: some View {
        LoadingContent(state: state, retry: { reload += 1 }) { loaded in
            VStack(spacing: 0) {
                let pending = loaded.0.ingredients.filter(\.amountNeedsReview).count
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
                RecipeEditorView(title: "Review Import", draft: loaded.0, destinationBooks: loaded.1,
                                 saveLabel: "Save Recipe", showsCancel: false) { reviewed in
                    try await service.approveImport(id: jobID, draft: reviewed)
                } onSaved: { _ in
                    onDone()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Discard Import", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            }
        }
        .confirmationDialog("Discard this import?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                runner.run {
                    try await service.discardImport(id: jobID)
                    onDone()
                    dismiss()
                }
            }
        }
        .task(id: reload) {
            do {
                async let draft = service.importReview(id: jobID)
                async let books = service.books()
                var reviewDraft = try await draft
                // The destination must be chosen explicitly by the user.
                reviewDraft.bookID = nil
                state = .loaded((reviewDraft, try await books))
            } catch let error where !error.isCancellation {
                state = .failed(error.localizedDescription)
            } catch {}
        }
        .errorAlert($runner.errorMessage)
    }
}
#endif
