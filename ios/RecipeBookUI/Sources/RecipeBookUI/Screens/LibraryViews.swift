#if os(iOS)
import SwiftUI
import RecipeBookPresentation

@MainActor
struct LibraryView: View {
    @Environment(\.recipeBookService) private var service
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var state: LoadState<[BookSummary]> = .loading
    @State private var reload = 0
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            LoadingContent(state: state, retry: { reload += 1 }) { books in
                if books.isEmpty {
                    ContentUnavailableView {
                        Label("No recipe books yet", systemImage: "books.vertical")
                    } description: {
                        Text("Start a personal book for your own recipes, or a shared book to collect recipes with others.")
                    } actions: {
                        Button("New Book") { showingCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            shelf("Shared", books.filter { $0.kind == .shared })
                            shelf("Personal", books.filter { $0.kind == .personal })
                        }
                        .padding()
                    }
                    .refreshable { await load() }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Library")
            .toolbar {
                Button { showingCreate = true } label: { Label("New Book", systemImage: "plus") }
            }
            .recipeDestinations()
            .sheet(isPresented: $showingCreate) {
                CreateBookSheet { _ in reload += 1 }
            }
        }
        .task(id: reload) { await load() }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ books: [BookSummary]) -> some View {
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                let columns = typeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : [GridItem(.adaptive(minimum: 160), spacing: 14)]
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(books) { book in
                        NavigationLink(value: book) { BookCover(book: book) }
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
    }
}

/// A book drawn as a cover with a coloured spine.
@MainActor
struct BookCover: View {
    let book: BookSummary

    var body: some View {
        let tint = RecipeBookTheme.tint(for: book.id)
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 8)
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: book.kind == .shared ? "person.2.fill" : "book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(book.name)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.recipeCount == 1 ? "1 recipe" : "\(book.recipeCount) recipes")
                    if book.kind == .shared {
                        Text(book.memberCount == 1 ? "1 member" : "\(book.memberCount) members")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(tint.opacity(0.10))
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.name), \(book.kind == .shared ? "shared book" : "personal book"), \(book.recipeCount) recipes")
        .accessibilityHint(book.myRole == .owner && book.kind == .shared ? "You are an owner" : "")
    }
}

@MainActor
struct CreateBookSheet: View {
    let onCreated: (BookSummary) -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: BookKind = .personal
    @State private var runner = ActionRunner()

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                    Text(kind == .personal
                         ? "Only you can see a personal book."
                         : "You’ll be the owner. Add people by account ID; everyone can view and add recipes, and members edit only their own.")
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
    @State private var showingLeave = false
    @State private var confirmDeleteBook = false
    @State private var recipePendingDelete: RecipeSummary?
    @State private var runner = ActionRunner()

    var body: some View {
        LoadingContent(state: state, retry: { reload += 1 }) { book in
            content(book)
        }
        .navigationTitle(state.value?.summary.name ?? summary.name)
        .task(id: reload) { await load() }
        .errorAlert($runner.errorMessage)
    }

    private func bookMenuActions(_ book: BookDetail, permissions: BookPermissions) -> [ToolbarAction] {
        var actions: [ToolbarAction] = []
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
                    Label(book.summary.kind == .shared ? "Shared book" : "Personal book",
                          systemImage: book.summary.kind == .shared ? "person.2" : "lock")
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

            Section("Recipes") {
                if book.recipes.isEmpty {
                    ContentUnavailableView {
                        Label("No recipes yet", systemImage: "fork.knife")
                    } description: {
                        Text("Add one by hand, or share a public Instagram Reel to Recipe Book.")
                    } actions: {
                        Button("Add Recipe") { showingEditor = true }
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
            primary: [ToolbarAction("Add Recipe", systemImage: "plus") { showingEditor = true }],
            secondary: bookMenuActions(book, permissions: permissions)
        )
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
    }
}

@MainActor
struct RecipeRow: View {
    let recipe: RecipeSummary
    let showAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.title)
                .font(.system(.body, design: .serif).weight(.medium))
            HStack(spacing: 12) {
                if let minutes = recipe.totalMinutes {
                    MetaLabel(text: formattedMinutes(minutes), systemImage: "clock")
                }
                if showAuthor {
                    MetaLabel(text: recipe.authorName, systemImage: "person")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
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
