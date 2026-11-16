#if os(iOS)
import SwiftUI
import RecipeBookPresentation

@MainActor
struct LibraryView: View {
    @Environment(\.recipeBookService) private var service
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessMode) private var accessMode
    @Environment(\.requestSignIn) private var requestSignIn
    @State private var state: LoadState<[BookSummary]> = .loading
    @State private var reload = 0
    @State private var showingCreate = false
    @State private var pendingSignIn = false
    @State private var jobs: [ImportJob] = []
    @State private var resumingImport: ImportJob?

    var body: some View {
        NavigationStack {
            LoadingContent(state: state, retry: { reload += 1 }) { books in
                if books.isEmpty && unfinishedImports.isEmpty {
                    VStack(spacing: 0) {
                        if accessMode == .guest { OnDeviceBanner().padding() }
                        ContentUnavailableView {
                            Label("No recipe books yet", systemImage: "books.vertical")
                        } description: {
                            Text(accessMode == .guest
                                 ? "Start a personal book for your own recipes. It’s saved on this iPhone."
                                 : "Start a personal book for your own recipes, or a shared book to collect recipes with others.")
                        } actions: {
                            Button("New Book") { showingCreate = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if accessMode == .guest { OnDeviceBanner() }
                            importsInProgress
                            let account = books.filter { $0.storage == .account }
                            let onDevice = books.filter { $0.storage == .onDevice }
                            shelf("Shared", account.filter { $0.kind == .shared })
                            shelf("Personal", account.filter { $0.kind == .personal })
                            shelf(accessMode == .guest ? "Personal" : "On This iPhone", onDevice,
                                  footer: accessMode == .guest ? nil
                                  : "Saved only on this device before you signed in. Open a book to copy it to your account.")
                        }
                        .padding()
                    }
                    .refreshable { await load() }
                }
            }
            // Inside the stack so it re-runs when returning from a book (seen drafts, new jobs).
            .task(id: reload) {
                await load()
                // Keep book badges current while something is importing; stops when this disappears.
                while !Task.isCancelled, accessMode == .account, jobs.contains(where: { $0.status.isInFlight }) {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    await loadJobs()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Library")
            .toolbar {
                Button { showingCreate = true } label: { Label("New Book", systemImage: "plus") }
            }
            .recipeDestinations()
            .sheet(isPresented: $showingCreate, onDismiss: {
                if pendingSignIn {
                    pendingSignIn = false
                    requestSignIn(.sharing)
                }
            }) {
                CreateBookSheet(onCreated: { _ in reload += 1 }, onSignInNeeded: { pendingSignIn = true })
            }
            .sheet(item: $resumingImport, onDismiss: { reload += 1 }) { job in
                ReelImportFlowView(start: .job(job.id), onClose: { resumingImport = nil })
            }
        }
    }

    private var activity: [BookID: BookImportActivity] { BookImportActivity.byBook(jobs) }

    /// Older imports that aren't bound to a book. Book-bound imports appear inside their book.
    private var unfinishedImports: [ImportJob] {
        jobs.filter { job in
            guard job.bookID == nil else { return false }
            if case .completed = job.status { return false }
            return true
        }
    }

    /// Unfinished Instagram imports (account only). The job lives on the server, so the user can
    /// leave the import sheet at any time and pick it up here.
    @ViewBuilder
    private var importsInProgress: some View {
        if !unfinishedImports.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Imports in progress")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(unfinishedImports) { job in
                        Button { resumingImport = job } label: {
                            ImportJobRow(job: job)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens this import")
                        if job.id != unfinishedImports.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ books: [BookSummary], footer: String? = nil) -> some View {
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                let columns = typeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : [GridItem(.adaptive(minimum: 160), spacing: 14)]
                let activity = self.activity
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(books) { book in
                        NavigationLink(value: book) { BookCover(book: book, imports: activity[book.id] ?? BookImportActivity()) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await service.books())
        } catch let error where !error.isCancellation {
            state = .failed(error.localizedDescription)
        } catch {}
        await loadJobs()
    }

    private func loadJobs() async {
        guard accessMode == .account else { jobs = []; return }
        // Secondary content: a failure here shouldn't block the library.
        if let latest = try? await service.importJobs() { jobs = latest }
    }
}

/// A book cover: real cover photo when one exists, otherwise an illustrative tinted cover.
@MainActor
struct BookCover: View {
    let book: BookSummary
    var imports = BookImportActivity()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                CoverImage(image: book.coverImage, seed: book.id,
                           symbol: book.kind == .shared ? "person.2.fill" : "book.closed.fill")
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        ImportActivityBadge(activity: imports).padding(8)
                    }
                HStack(spacing: 6) {
                    if book.kind == .shared {
                        Label("Shared", systemImage: "person.2.fill")
                    }
                    if book.storage == .onDevice {
                        Label("On this iPhone", systemImage: "iphone")
                    }
                }
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.name), \(book.kind == .shared ? "shared book" : "personal book")\(book.storage == .onDevice ? ", on this iPhone" : ""), \(book.recipeCount) recipes\(imports.accessibilityText.map { ", \($0)" } ?? "")")
        .accessibilityHint(book.myRole == .owner && book.kind == .shared ? "You are an owner" : "")
    }

    private var subtitle: String {
        var parts = [book.recipeCount == 1 ? "1 recipe" : "\(book.recipeCount) recipes"]
        if book.kind == .shared {
            parts.append(book.memberCount == 1 ? "1 member" : "\(book.memberCount) members")
        }
        if book.storage == .onDevice { parts.append("On this iPhone") }
        return parts.joined(separator: " · ")
    }
}

/// Book cover corner badge: a spinner while Reels import into the book, otherwise the number of
/// new drafts waiting for review, or a failure marker. Hidden when there's no activity.
@MainActor
struct ImportActivityBadge: View {
    let activity: BookImportActivity

    var body: some View {
        Group {
            if activity.inProgress > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(activity.inProgress == 1 ? "Importing" : "Importing \(activity.inProgress)")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
            } else if activity.newReady > 0 {
                Label("\(activity.newReady) new", systemImage: "sparkles")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RecipeBookTheme.accent, in: Capsule())
            } else if activity.failed > 0 {
                Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.red, in: Circle())
            }
        }
        .font(.caption.weight(.semibold))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

@MainActor
struct CreateBookSheet: View {
    let onCreated: (BookSummary) -> Void
    /// Called when a guest asks to create a shared book; the presenter shows sign-in after dismissal.
    var onSignInNeeded: () -> Void = {}
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessMode) private var accessMode
    @State private var name = ""
    @State private var kind: BookKind = .personal
    @State private var runner = ActionRunner()

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var needsSignIn: Bool { accessMode == .guest && kind == .shared }

    private var footer: String {
        switch (kind, accessMode) {
        case (.personal, .guest):
            return "Saved only on this iPhone. Only you can see it."
        case (.personal, .account):
            return "Only you can see a personal book."
        case (.shared, .guest):
            return "Shared books are stored in a Recipe Book account so others can join. Sign in with Google to create one."
        case (.shared, .account):
            return "You’ll be the owner. Add people by account ID; everyone can view and add recipes, and members edit only their own."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Weeknight Dinners", text: $name)
                }
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Personal").tag(BookKind.personal)
                        Text("Shared").tag(BookKind.shared)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("New Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else if needsSignIn {
                        Button("Sign In") {
                            onSignInNeeded()
                            dismiss()
                        }
                    } else {
                        Button("Create") {
                            let name = trimmed, kind = kind
                            runner.run {
                                let book = try await service.createBook(name: name, kind: kind)
                                onCreated(book)
                                dismiss()
                            }
                        }
                        .disabled(trimmed.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .errorAlert($runner.errorMessage)
    }
}

// MARK: - Book

@MainActor
struct BookView: View {
    let summary: BookSummary
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<BookDetail> = .loading
    @State private var reload = 0
    @State private var search = ""
    @State private var showingEditor = false
    @State private var showingAddChoice = false
    @State private var showingImport = false
    @State private var imports: [ImportJob] = []
    @State private var openingImport: ImportJob?
    @State private var importPendingDiscard: ImportJob?
    @State private var showingLeave = false
    @State private var confirmDeleteBook = false
    @State private var recipePendingDelete: RecipeSummary?
    @State private var showingCopy = false
    @State private var copiedBook: BookSummary?
    @State private var pendingCopiedBook: BookSummary?
    @State private var runner = ActionRunner()
    @Environment(\.accessMode) private var accessMode
    @Environment(\.requestSignIn) private var requestSignIn

    var body: some View {
        LoadingContent(state: state, retry: { reload += 1 }) { book in
            content(book)
        }
        .navigationTitle(state.value?.summary.name ?? summary.name)
        .task(id: reload) {
            await load()
            // Pending import cards update while the server works; stops when the book closes.
            while !Task.isCancelled, imports.contains(where: { $0.status.isInFlight }) {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await loadImports()
            }
        }
        .errorAlert($runner.errorMessage)
    }

    private func bookMenuActions(_ book: BookDetail, permissions: BookPermissions) -> [ToolbarAction] {
        var actions: [ToolbarAction] = []
        if book.summary.storage == .onDevice {
            actions.append(ToolbarAction("Share…", systemImage: "person.2.badge.plus") {
                if accessMode == .guest {
                    requestSignIn(.sharing)
                } else {
                    showingCopy = true
                }
            })
        }
        if book.summary.kind == .shared {
            actions.append(ToolbarAction("Leave Book…", systemImage: "rectangle.portrait.and.arrow.right") { showingLeave = true })
        }
        if permissions.canDeleteBook {
            actions.append(ToolbarAction("Delete Book…", systemImage: "trash", role: .destructive) { confirmDeleteBook = true })
        }
        return actions
    }

    @ViewBuilder
    private func content(_ book: BookDetail) -> some View {
        let permissions = BookPermissions(book: book)
        let recipes = book.recipes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        List {
            Section {
                HStack(spacing: 12) {
                    if book.summary.storage == .onDevice {
                        Label("Personal book on this iPhone", systemImage: "iphone")
                    } else {
                        Label(book.summary.kind == .shared ? "Shared book" : "Personal book",
                              systemImage: book.summary.kind == .shared ? "person.2" : "lock")
                    }
                    Spacer()
                    if book.summary.kind == .shared { RoleBadge(role: book.summary.myRole) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if book.summary.kind == .shared {
                    NavigationLink {
                        MembersView(bookID: book.id) { reload += 1 } onLeft: { dismiss() }
                    } label: {
                        Label(book.members.count == 1 ? "1 member" : "\(book.members.count) members",
                              systemImage: "person.2.circle")
                    }
                }
            }

            if !imports.isEmpty {
                Section {
                    ForEach(imports) { job in
                        PendingImportCard(job: job, isRunning: runner.isRunning,
                                          onReview: { openingImport = job },
                                          onRetry: {
                                              runner.run {
                                                  _ = try await service.retryImport(id: job.id)
                                                  reload += 1
                                              }
                                          },
                                          onDiscard: { importPendingDiscard = job })
                    }
                } header: {
                    Text("From Instagram")
                } footer: {
                    Text("Imports keep going with the app closed. Nothing is added to the book until you review and save it.")
                }
            }

            Section("Recipes") {
                if book.recipes.isEmpty && !imports.isEmpty {
                    Text("Reviewed imports and recipes you write appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if book.recipes.isEmpty {
                    ContentUnavailableView {
                        Label("No recipes yet", systemImage: "fork.knife")
                    } description: {
                        Text(accessMode == .guest
                             ? "Write one yourself. Sign in to import recipes from Instagram Reels."
                             : "Write one yourself, or paste an Instagram Reel link — sharing a Reel to Recipe Book works too.")
                    } actions: {
                        Button("Add Recipe") { showingAddChoice = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if recipes.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(recipes) { recipe in
                        NavigationLink(value: RecipeRoute(id: recipe.id, title: recipe.title)) {
                            RecipeRow(recipe: recipe, showAuthor: book.summary.kind == .shared)
                        }
                        .swipeActions {
                            if permissions.canDelete(recipe) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    recipePendingDelete = recipe
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search recipes")
        .refreshable { await load() }
        .adaptiveToolbar(
            primary: [ToolbarAction("Add Recipe", systemImage: "plus") { showingAddChoice = true }],
            secondary: bookMenuActions(book, permissions: permissions)
        )
        .confirmationDialog("Add Recipe", isPresented: $showingAddChoice) {
            Button("Write Recipe") { showingEditor = true }
            Button("Paste Instagram Link") {
                if accessMode == .guest {
                    requestSignIn(.importing)
                } else {
                    showingImport = true
                }
            }
        } message: {
            Text("Write a recipe yourself, or import one from a public Instagram Reel.")
        }
        .sheet(isPresented: $showingImport, onDismiss: { reload += 1 }) {
            // Imports land in account books; a book on this iPhone isn't preselected.
            ReelImportFlowView(start: .paste,
                               preselectedBookID: book.summary.storage == .account ? book.id : nil,
                               onClose: { showingImport = false })
        }
        .sheet(item: $openingImport, onDismiss: { reload += 1 }) { job in
            ReelImportFlowView(start: .job(job.id), preselectedBookID: book.id, onClose: { openingImport = nil })
        }
        .confirmationDialog("Discard this import?",
                            isPresented: Binding(get: { importPendingDiscard != nil },
                                                 set: { if !$0 { importPendingDiscard = nil } }),
                            titleVisibility: .visible) {
            Button("Discard Import", role: .destructive) {
                guard let job = importPendingDiscard else { return }
                runner.run {
                    try await service.discardImport(id: job.id)
                    reload += 1
                }
            }
        } message: {
            Text("The draft and its source text will be removed. The Reel stays on Instagram.")
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                RecipeEditorView(title: "New Recipe", draft: RecipeDraft(bookID: book.id), destinationBooks: nil,
                                 saveLabel: "Save") { draft in
                    try await service.saveRecipe(draft)
                } onSaved: { _ in
                    reload += 1
                }
            }
        }
        .sheet(isPresented: $showingLeave) {
            LeaveBookSheet(book: book) { dismiss() }
        }
        .sheet(isPresented: $showingCopy, onDismiss: {
            copiedBook = pendingCopiedBook
            pendingCopiedBook = nil
        }) {
            CopyToAccountSheet(book: book.summary) { pendingCopiedBook = $0 }
        }
        .alert("Copied to your account",
               isPresented: Binding(get: { copiedBook != nil }, set: { if !$0 { copiedBook = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(copiedBook?.kind == .shared
                 ? "“\(copiedBook?.name ?? "")” is now a shared book in your Library. Open it to add people. The original stays on this iPhone."
                 : "“\(copiedBook?.name ?? "")” is now in your Library. The original stays on this iPhone.")
        }
        .confirmationDialog("Delete “\(book.summary.name)”?", isPresented: $confirmDeleteBook, titleVisibility: .visible) {
            Button("Delete Book and All Recipes", role: .destructive) {
                runner.run {
                    try await service.deleteBook(id: book.id)
                    dismiss()
                }
            }
        } message: {
            Text(book.summary.kind == .shared
                 ? "All recipes in this book will be deleted for every member. This can’t be undone."
                 : "All recipes in this book will be deleted. This can’t be undone.")
        }
        .confirmationDialog("Delete “\(recipePendingDelete?.title ?? "")”?",
                            isPresented: Binding(get: { recipePendingDelete != nil },
                                                 set: { if !$0 { recipePendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) {
                guard let recipe = recipePendingDelete else { return }
                runner.run {
                    try await service.deleteRecipe(id: recipe.id)
                    reload += 1
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
        .disabled(runner.isRunning)
    }

    private func load() async {
        do {
            state = .loaded(try await service.book(id: summary.id))
        } catch let error where !error.isCancellation {
            if state.value == nil {
                state = .failed(error.localizedDescription)
            } else {
                runner.errorMessage = error.localizedDescription
            }
        } catch {}
        await loadImports()
        // Opening the book acknowledges its new drafts. Persisted by the service; the cards stay
        // until each draft is saved or discarded, and the Library badge updates from the server.
        for job in imports where job.status == .reviewRequired && job.isUnseen {
            try? await service.markImportSeen(id: job.id)
        }
    }

    private func loadImports() async {
        guard accessMode == .account, summary.storage == .account else { imports = []; return }
        // Secondary content: a failure here shouldn't block the book.
        guard let jobs = try? await service.importJobs() else { return }
        imports = jobs.filter { job in
            guard job.bookID == summary.id else { return false }
            if case .completed = job.status { return false }
            return true
        }
    }
}

/// A Reel importing into this book: a placeholder card with the backend's stage while it works,
/// then the draft to review, or the failure reason with Retry / Discard.
@MainActor
struct PendingImportCard: View {
    let job: ImportJob
    let isRunning: Bool
    let onReview: () -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    CoverImage(image: job.thumbnail, seed: job.id, symbol: "play.rectangle.fill")
                    if job.status.isInFlight {
                        Color.black.opacity(0.3)
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(job.status.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                        if job.status == .reviewRequired && job.isUnseen {
                            Text("New")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RecipeBookTheme.accent, in: Capsule())
                        }
                    }
                    if let title = job.titleHint {
                        Text(title)
                            .font(.system(.body, design: .serif).weight(.semibold))
                            .lineLimit(2)
                    } else if job.status.isInFlight {
                        // Placeholder for the recipe that is still being read.
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: 150, height: 14)
                            .accessibilityHidden(true)
                    } else {
                        Text("Instagram Reel")
                            .font(.system(.body, design: .serif).weight(.semibold))
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            actions
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var actions: some View {
        switch job.status {
        case .reviewRequired:
            Button(action: onReview) {
                Label("Review Recipe", systemImage: "checklist").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
        case .failed(_, let canRetry):
            HStack(spacing: 10) {
                if canRetry {
                    Button(action: onRetry) {
                        Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive, action: onDiscard) {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(isRunning)
        case .queued, .processing:
            WatchOnInstagramButton(url: job.sourceURL, compact: true)
        case .completed:
            EmptyView()
        }
    }

    private var detail: String {
        switch job.status {
        case .queued: return job.stageDetail ?? "Waiting to start. You can close the app."
        case .processing: return job.stageDetail ?? "Reading the caption, comments and spoken audio."
        case .reviewRequired: return "Draft ready. Check the ingredients and steps before it’s saved."
        case .failed(let reason, _): return reason
        case .completed: return "Saved."
        }
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

@MainActor
struct RecipeRow: View {
    let recipe: RecipeSummary
    let showAuthor: Bool

    var body: some View {
        HStack(spacing: 14) {
            RecipeThumbnail(recipe: recipe, size: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(recipe.title)
                    .font(.system(.body, design: .serif).weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let style = recipe.mealStyle {
                        MealStyleBadge(style: style)
                    }
                    if let minutes = recipe.totalMinutes {
                        MetaLabel(text: formattedMinutes(minutes), systemImage: "clock")
                    }
                }
                .font(.caption)
                if showAuthor {
                    MetaLabel(text: recipe.authorName, systemImage: "person")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Members

@MainActor
struct MembersView: View {
    let bookID: BookID
    let onChanged: () -> Void
    let onLeft: () -> Void
    @Environment(\.recipeBookService) private var service
    @State private var state: LoadState<BookDetail> = .loading
    @State private var reload = 0
    @State private var newAccountID = ""
    @State private var memberPendingRemoval: BookMember?
    @State private var showingLeave = false
    @State private var runner = ActionRunner()

    var body: some View {
        LoadingContent(state: state, retry: { reload += 1 }) { book in
            list(book)
        }
        .navigationTitle("Members")
        .task(id: reload) {
            do {
                state = .loaded(try await service.book(id: bookID))
            } catch let error where !error.isCancellation {
                state = .failed(error.localizedDescription)
            } catch {}
        }
        .errorAlert($runner.errorMessage)
    }

    private func list(_ book: BookDetail) -> some View {
        let permissions = BookPermissions(book: book)
        let normalizedID = AccountIDInput.normalize(newAccountID)
        return List {
            Section {
                ForEach(permissions.owners) { memberRow($0, book: book, permissions: permissions) }
            } header: {
                Text("Owners")
            } footer: {
                Text("Owners manage every recipe and the member list. A book can have several owners.")
            }
            let members = book.members.filter { $0.role == .member }
            if !members.isEmpty {
                Section("Members") {
                    ForEach(members) { memberRow($0, book: book, permissions: permissions) }
                }
            }
            if permissions.canManageMembers {
                Section {
                    TextField("Account ID", text: $newAccountID)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        guard let id = normalizedID else { return }
                        runner.run {
                            state = .loaded(try await service.addMember(accountID: id, to: book.id))
                            newAccountID = ""
                            onChanged()
                        }
                    } label: {
                        Label("Add Member", systemImage: "person.badge.plus")
                    }
                    .disabled(normalizedID == nil || runner.isRunning)
                } header: {
                    Text("Add someone")
                } footer: {
                    if !newAccountID.isEmpty && normalizedID == nil {
                        Text("That isn’t a valid account ID.").foregroundStyle(.red)
                    } else {
                        Text("Ask them to open Recipe Book and copy the account ID shown on their Account tab.")
                    }
                }
            }
            Section {
                Button("Leave Book…", role: .destructive) { showingLeave = true }
            }
        }
        .disabled(runner.isRunning)
        .sheet(isPresented: $showingLeave) {
            LeaveBookSheet(book: book, onLeft: onLeft)
        }
        .confirmationDialog("Remove \(memberPendingRemoval?.displayName ?? "")?",
                            isPresented: Binding(get: { memberPendingRemoval != nil },
                                                 set: { if !$0 { memberPendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from Book", role: .destructive) {
                guard let member = memberPendingRemoval else { return }
                runner.run {
                    state = .loaded(try await service.removeMember(member.id, from: book.id))
                    onChanged()
                }
            }
        } message: {
            Text("They’ll lose access to this book.")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: BookMember, book: BookDetail, permissions: BookPermissions) -> some View {
        let isMe = member.id == book.currentUserID
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(member.displayName) (You)" : member.displayName)
                Text(member.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityHidden(true)
            }
            Spacer()
            if permissions.canChangeRole(of: member) || permissions.canRemove(member) {
                Menu {
                    if permissions.canChangeRole(of: member) {
                        if member.role == .member {
                            Button("Make Owner", systemImage: "crown") { setRole(.owner, for: member, in: book) }
                        } else {
                            Button("Remove Owner Role", systemImage: "person") { setRole(.member, for: member, in: book) }
                        }
                    }
                    if permissions.canRemove(member) {
                        Button("Remove from Book", systemImage: "person.badge.minus", role: .destructive) {
                            memberPendingRemoval = member
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .accessibilityLabel("Actions for \(member.displayName)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func setRole(_ role: MemberRole, for member: BookMember, in book: BookDetail) {
        runner.run {
            state = .loaded(try await service.changeRole(of: member.id, to: role, in: book.id))
            onChanged()
        }
    }
}

// MARK: - Leaving

/// Lets the last owner pick a successor or delete the book. Nothing is chosen automatically.
@MainActor
struct LastOwnerResolutionPicker: View {
    let candidates: [BookMember]
    @Binding var selection: LastOwnerResolution?

    var body: some View {
        ForEach(candidates) { member in
            choice(.transferOwnership(to: member.id), title: "Make \(member.displayName) the owner",
                   systemImage: "crown")
        }
        choice(.deleteBook, title: "Delete the book for everyone", systemImage: "trash", destructive: true)
    }

    private func choice(_ value: LastOwnerResolution, title: String, systemImage: String,
                        destructive: Bool = false) -> some View {
        Button {
            selection = value
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer()
                if selection == value {
                    Image(systemName: "checkmark").foregroundStyle(RecipeBookTheme.accent)
                }
            }
        }
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

@MainActor
struct LeaveBookSheet: View {
    let book: BookDetail
    let onLeft: () -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var resolution: LastOwnerResolution?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                switch BookPermissions(book: book).leaveRequirement {
                case .canLeave:
                    Section {
                        Text("You’ll no longer see “\(book.summary.name)” or be able to add recipes to it.")
                    }
                    Section { submit(title: "Leave Book", resolution: nil) }
                case .lastOwnerMustTransferOrDelete(let candidates):
                    Section {
                        LastOwnerResolutionPicker(candidates: candidates, selection: $resolution)
                    } header: {
                        Text("You’re the last owner")
                    } footer: {
                        Text("Choose who takes over, or delete the book. Recipe Book never picks a new owner for you.")
                    }
                    Section {
                        submit(title: resolution == .deleteBook ? "Delete Book and Leave" : "Transfer and Leave",
                               resolution: resolution)
                            .disabled(resolution == nil)
                    }
                case .soleMemberMustDelete:
                    Section {
                        Text("You’re the only member, so leaving will delete “\(book.summary.name)” and its recipes.")
                    }
                    Section { submit(title: "Delete Book", resolution: .deleteBook) }
                case .personalBookDeleteOnly:
                    Section {
                        Text("Personal books can’t be left. Delete the book instead.")
                    }
                }
            }
            .navigationTitle("Leave Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancel(); dismiss() }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .errorAlert($runner.errorMessage)
    }

    private func submit(title: String, resolution: LastOwnerResolution?) -> some View {
        RunningButton(title: title, role: .destructive, isRunning: runner.isRunning) {
            runner.run {
                if resolution == .deleteBook && BookPermissions(book: book).leaveRequirement == .soleMemberMustDelete {
                    try await service.deleteBook(id: book.id)
                } else {
                    try await service.leaveBook(id: book.id, resolution: resolution)
                }
                dismiss()
                onLeft()
            }
        }
    }
}
#endif
