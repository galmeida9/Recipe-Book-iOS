#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// MARK: - Shopping lists (personal)

@MainActor

struct ShoppingListsView: View {
    @Environment(\.recipeBookService) private var service
    @State private var state: LoadState<[ShoppingListSummary]> = .loading
    @State private var reload = 0
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var listPendingDelete: ShoppingListSummary?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            LoadingContent(state: state, retry: { reload += 1 }) { lists in
                if lists.isEmpty {
                    ContentUnavailableView {
                        Label("No shopping lists", systemImage: "cart")
                    } description: {
                        Text("Create a list, or add ingredients from any recipe.")
                    } actions: {
                        Button("New List") { showingCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(lists) { list in
                            NavigationLink(value: list) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name).font(.body.weight(.medium))
                                    Text(list.remainingCount == 0 && list.totalCount > 0
                                         ? "All bought"
                                         : "\(list.remainingCount) of \(list.totalCount) to buy")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { listPendingDelete = list }
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Shopping")
            .toolbar {
                Button { showingCreate = true } label: { Label("New List", systemImage: "plus") }
            }
            .navigationDestination(for: ShoppingListSummary.self) { ShoppingListView(listID: $0.id, title: $0.name) }
            .alert("New Shopping List", isPresented: $showingCreate) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newName = ""
                    guard !name.isEmpty else { return }
                    runner.run {
                        _ = try await service.createShoppingList(name: name)
                        reload += 1
                    }
                }
            }
            .confirmationDialog("Delete “\(listPendingDelete?.name ?? "")”?",
                                isPresented: Binding(get: { listPendingDelete != nil },
                                                     set: { if !$0 { listPendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete List", role: .destructive) {
                    guard let list = listPendingDelete else { return }
                    runner.run {
                        try await service.deleteShoppingList(id: list.id)
                        reload += 1
                    }
                }
            }
        }
        .task(id: reload) { await load() }
        .errorAlert($runner.errorMessage)
    }

    private func load() async {
        do {
            state = .loaded(try await service.shoppingLists())
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

struct ShoppingListView: View {
    let listID: ShoppingListID
    let title: String
    @Environment(\.recipeBookService) private var service
    @State private var state: LoadState<ShoppingList> = .loading
    @State private var reload = 0
    /// Items with a request in flight; prevents double toggles on the same row.
    @State private var pending: Set<ShoppingItemID> = []
    @State private var errorMessage: String?
    @State private var newItem = ""
    @State private var newAmount = ""
    @State private var adding = false
    @FocusState private var addFocused: Bool

    var body: some View {
        LoadingContent(state: state, retry: { reload += 1 }) { list in
            content(list)
        }
        .navigationTitle(state.value?.name ?? title)
        .task(id: reload) {
            do {
                state = .loaded(try await service.shoppingList(id: listID))
            } catch let error where !error.isCancellation {
                state = .failed(error.localizedDescription)
            } catch {}
        }
        .errorAlert($errorMessage)
    }

    private func content(_ list: ShoppingList) -> some View {
        let toBuy = list.items.filter { !$0.isBought }
        let bought = list.items.filter(\.isBought)
        return List {
            if list.items.isEmpty {
                ContentUnavailableView("Nothing on this list",
                                       systemImage: "cart",
                                       description: Text("Add items below, or from a recipe’s ingredients."))
                    .listRowBackground(Color.clear)
            }
            if !toBuy.isEmpty {
                Section("To buy") {
                    ForEach(toBuy) { itemRow($0) }
                }
            }
            if !bought.isEmpty {
                Section("Bought") {
                    ForEach(bought) { itemRow($0) }
                }
            }
        }
        .refreshable { reload += 1 }
        .safeAreaInset(edge: .bottom) { addBar }
    }

    private func itemRow(_ item: ShoppingItem) -> some View {
        Button {
            mutate(item.id) { try await service.setShoppingItem(item.id, bought: !item.isBought, in: listID) }
        } label: {
            HStack(spacing: 12) {
                if pending.contains(item.id) {
                    ProgressView().frame(width: 24)
                } else {
                    Image(systemName: item.isBought ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isBought ? RecipeBookTheme.success : Color.secondary)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .strikethrough(item.isBought)
                        .foregroundStyle(item.isBought ? Color.secondary : Color.primary)
                    HStack(spacing: 6) {
                        if let amount = QuantityText.display(quantity: item.quantity, unit: item.unit) {
                            Text(amount).monospacedDigit()
                        }
                        if let source = item.sourceRecipeTitle {
                            Text("for \(source)").lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending.contains(item.id))
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isBought ? "Bought" : "Not bought")
        .accessibilityHint(item.isBought ? "Double-tap to mark as not bought" : "Double-tap to mark as bought")
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                mutate(item.id) { try await service.removeShoppingItem(item.id, from: listID) }
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("Add item", text: $newItem)
                .focused($addFocused)
                .submitLabel(.done)
                .onSubmit(addItem)
            TextField("Amount", text: $newAmount)
                .frame(maxWidth: 90)
                .accessibilityHint("Optional, for example 500 g")
            Button(action: addItem) {
                if adding { ProgressView() } else { Image(systemName: "plus.circle.fill").font(.title2) }
            }
            .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            .accessibilityLabel("Add item")
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Splits "500 g" into a quantity and unit; anything unparseable stays as unit-less text.
    private func parseAmount(_ text: String) -> (String?, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        if case .success(let q?) = QuantityText.normalize(parts[0]) {
            return (q, parts.count > 1 ? parts[1] : nil)
        }
        if case .success(let q?) = QuantityText.normalize(trimmed) {
            return (q, nil)
        }
        return (nil, trimmed)
    }

    private func addItem() {
        let name = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !adding else { return }
        let (quantity, unit) = parseAmount(newAmount)
        adding = true
        Task {
            do {
                state = .loaded(try await service.addShoppingItem(
                    ShoppingItemDraft(name: name, quantity: quantity, unit: unit), to: listID))
                newItem = ""
                newAmount = ""
                addFocused = true
            } catch let error where !error.isCancellation {
                errorMessage = error.localizedDescription
            } catch {}
            adding = false
        }
    }

    private func mutate(_ itemID: ShoppingItemID, _ operation: @escaping () async throws -> ShoppingList) {
        guard !pending.contains(itemID) else { return }
        pending.insert(itemID)
        Task {
            do {
                state = .loaded(try await operation())
            } catch {
                errorMessage = error.localizedDescription
            }
            pending.remove(itemID)
        }
    }
}

// MARK: - Account

@MainActor

struct AccountView: View {
    let profile: UserProfile
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service
    @State private var showingDelete = false
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: profile.displayName)
                } header: {
                    Text("Profile")
                }
                Section {
                    AccountIDView(accountID: profile.id)
                } header: {
                    Text("Account ID")
                } footer: {
                    Text("Book owners use this to add you to a shared book.")
                }
                Section("About") {
                    Label("Suggestions use only recipes saved in your books.", systemImage: "lock.shield")
                    Label("Imports work with public Instagram Reels; you always review before saving.", systemImage: "film")
                    Label("Shopping lists are private to you.", systemImage: "cart")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Section {
                    Button {
                        runner.run {
                            try await service.signOut()
                            onChange(.signedOut)
                        }
                    } label: {
                        HStack {
                            Text("Sign Out")
                            if runner.isRunning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(runner.isRunning)
                }
                Section {
                    Button("Delete Account…", role: .destructive) { showingDelete = true }
                }
            }
            .navigationTitle("Account")
            .sheet(isPresented: $showingDelete) {
                DeleteAccountView { onChange(.signedOut) }
            }
        }
        .errorAlert($runner.errorMessage)
    }
}

/// Account deletion. Every shared book where the user is the last owner needs an explicit
/// transfer-or-delete choice first; nothing is promoted automatically.
@MainActor
struct DeleteAccountView: View {
    let onDeleted: () -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[BookDetail]> = .loading
    @State private var reload = 0
    @State private var resolutions: [BookID: LastOwnerResolution] = [:]
    @State private var confirm = false
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            LoadingContent(state: state, retry: { reload += 1 }) { blockers in
                form(blockers)
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancel(); dismiss() }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .task(id: reload) {
            do {
                state = .loaded(try await service.accountDeletionBlockers())
            } catch let error where !error.isCancellation {
                state = .failed(error.localizedDescription)
            } catch {}
        }
        .errorAlert($runner.errorMessage)
    }

    private func form(_ blockers: [BookDetail]) -> some View {
        let unresolved = blockers.filter { resolutions[$0.id] == nil }
        return Form {
            Section {
                Text("Your personal books, recipes and shopping lists will be deleted. You’ll be removed from shared books. This can’t be undone.")
            }
            ForEach(blockers) { book in
                Section {
                    LastOwnerResolutionPicker(
                        candidates: book.members.filter { $0.id != book.currentUserID },
                        selection: Binding(get: { resolutions[book.id] }, set: { resolutions[book.id] = $0 }))
                } header: {
                    Text("You’re the last owner of “\(book.summary.name)”")
                }
            }
            Section {
                RunningButton(title: "Delete Account", role: .destructive, isRunning: runner.isRunning) {
                    confirm = true
                }
                .disabled(!unresolved.isEmpty)
            } footer: {
                if !unresolved.isEmpty {
                    Text("Choose what happens to each book above first.")
                }
            }
        }
        .confirmationDialog("Delete your account permanently?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                let chosen = resolutions
                runner.run {
                    try await service.deleteAccount(resolutions: chosen)
                    dismiss()
                    onDeleted()
                }
            }
        }
    }
}
#endif
