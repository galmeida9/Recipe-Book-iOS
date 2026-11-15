#if os(iOS)
import SwiftUI
import PhotosUI
import RecipeBookPresentation

@MainActor
struct RecipeDetailView: View {
    let route: RecipeRoute
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Loaded> = .loading
    @State private var reload = 0
    @State private var showingEditor = false
    @State private var showingShopping = false
    @State private var confirmDelete = false
    @State private var runner = ActionRunner()

    struct Loaded {
        var recipe: RecipeDetail
        var book: BookDetail
    }

    var body: some View {
        LoadingContent(state: state, retry: { reload += 1 }) { loaded in
            content(loaded)
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reload) { await load() }
        .errorAlert($runner.errorMessage)
    }

    private func content(_ loaded: Loaded) -> some View {
        let recipe = loaded.recipe
        let permissions = BookPermissions(book: loaded.book)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(recipe)
                VStack(alignment: .leading, spacing: 28) {
                    header(recipe, book: loaded.book)
                    sourceCard(recipe)
                    ingredients(recipe)
                    steps(recipe)
                }
                .padding(20)
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .navigationSubtitleIfAvailable(loaded.book.summary.name)
        .bottomControlBar(isPresented: !recipe.ingredients.isEmpty) {
            Button { showingShopping = true } label: {
                Label("Add to Shopping List", systemImage: "cart.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .floatingPrimaryButtonStyle()
            .controlSize(.large)
        }
        .adaptiveToolbar(
            primary: permissions.canEdit(recipe.summary)
                ? [ToolbarAction("Edit", systemImage: "pencil") { showingEditor = true }]
                : [],
            secondary: permissions.canDelete(recipe.summary)
                ? [ToolbarAction("Delete Recipe…", systemImage: "trash", role: .destructive) { confirmDelete = true }]
                : []
        )
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                RecipeEditorView(title: "Edit Recipe", draft: RecipeDraft(editing: recipe), destinationBooks: nil,
                                 saveLabel: "Save") { draft in
                    try await service.saveRecipe(draft)
                } onSaved: { saved in
                    state = .loaded(Loaded(recipe: saved, book: loaded.book))
                }
            }
        }
        .sheet(isPresented: $showingShopping) {
            AddToShoppingListSheet(recipe: recipe)
        }
        .confirmationDialog("Delete “\(recipe.summary.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) {
                runner.run {
                    try await service.deleteRecipe(id: recipe.id)
                    dismiss()
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
        .disabled(runner.isRunning)
    }

    /// Real cover photo when there is one; otherwise a slim illustrative band, never a fake photo.
    @ViewBuilder
    private func hero(_ recipe: RecipeDetail) -> some View {
        if recipe.summary.coverImage != nil {
            CoverImage(image: recipe.summary.coverImage, seed: recipe.id,
                       symbol: recipe.summary.mealStyle?.systemImage ?? "fork.knife")
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 8)
        } else {
            CoverPlaceholder(seed: recipe.id, symbol: recipe.summary.mealStyle?.systemImage ?? "fork.knife")
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
    }

    /// Imported recipes link back to the original Reel so it can be watched on Instagram.
    @ViewBuilder
    private func sourceCard(_ recipe: RecipeDetail) -> some View {
        if let watch = ReelLink.watchURL(for: recipe.sourceURL) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Imported from an Instagram Reel", systemImage: "film")
                    .font(.subheadline.weight(.semibold))
                Text(watch.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                WatchOnInstagramButton(url: watch)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if let source = recipe.sourceURL, source.scheme?.lowercased() == "https" {
            Link(destination: source) {
                Label("View original", systemImage: "arrow.up.right.square")
            }
            .font(.subheadline)
        }
    }

    private func header(_ recipe: RecipeDetail, book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(book.summary.name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(RecipeBookTheme.tint(for: book.id))
            Text(recipe.summary.title)
                .displayTitle()
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { metadata(recipe, shared: book.summary.kind == .shared) }
                VStack(alignment: .leading, spacing: 6) { metadata(recipe, shared: book.summary.kind == .shared) }
            }
        }
    }

    @ViewBuilder
    private func metadata(_ recipe: RecipeDetail, shared: Bool) -> some View {
        if let style = recipe.summary.mealStyle {
            MealStyleBadge(style: style)
        }
        if let minutes = recipe.summary.totalMinutes {
            MetaLabel(text: formattedMinutes(minutes), systemImage: "clock")
        }
        if let servings = recipe.summary.servings {
            MetaLabel(text: servings == 1 ? "1 serving" : "\(servings) servings", systemImage: "person.2")
        }
        if shared {
            MetaLabel(text: "Added by \(recipe.summary.authorName)", systemImage: "person.crop.circle")
        }
    }

    private func ingredients(_ recipe: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Ingredients")
            if recipe.ingredients.isEmpty {
                Text("No ingredients listed.").foregroundStyle(.secondary)
            }
            ForEach(recipe.ingredients) { line in
                IngredientDisplayRow(line: line)
                if line.id != recipe.ingredients.last?.id { Divider() }
            }
        }
    }

    private func steps(_ recipe: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("Method")
            if recipe.steps.isEmpty {
                Text("No steps yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(RecipeBookTheme.accent)
                        .frame(minWidth: 24, alignment: .trailing)
                    Text(step.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1). \(step.text)")
            }
        }
    }

    private func load() async {
        do {
            let recipe = try await service.recipe(id: route.id)
            let book = try await service.book(id: recipe.summary.bookID)
            state = .loaded(Loaded(recipe: recipe, book: book))
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
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.title2, design: .serif).weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
struct IngredientDisplayRow: View {
    let line: IngredientLine
    @ScaledMetric(relativeTo: .body) private var amountWidth: CGFloat = 76

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            AmountText(quantity: line.quantity, unit: line.unit)
                .font(.body.weight(.medium))
                .frame(width: amountWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                if let prep = line.preparation, !prep.isEmpty {
                    Text(prep).font(.subheadline).foregroundStyle(.secondary)
                }
                if let original = line.originalText, !original.isEmpty, original != line.name {
                    Text("As written: \(original)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Have / need → shopping list

@MainActor
struct AddToShoppingListSheet: View {
    let recipe: RecipeDetail
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var lists: LoadState<[ShoppingListSummary]> = .loading
    @State private var reload = 0
    @State private var selectedListID: ShoppingListID?
    @State private var newListName = "Shopping"
    @State private var selection = IngredientSelection()
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            LoadingContent(state: lists, retry: { reload += 1 }) { lists in
                form(lists)
            }
            .navigationTitle("Add to Shopping List")
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
                let loaded = try await service.shoppingLists()
                lists = .loaded(loaded)
                if selectedListID == nil { selectedListID = loaded.first?.id }
            } catch let error where !error.isCancellation {
                lists = .failed(error.localizedDescription)
            } catch {}
        }
        .errorAlert($runner.errorMessage)
    }

    private func form(_ lists: [ShoppingListSummary]) -> some View {
        let needed = selection.needed(from: recipe.ingredients)
        let newName = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSubmit = !needed.isEmpty && (selectedListID != nil || !newName.isEmpty)
        return Form {
            Section("List") {
                if lists.isEmpty {
                    TextField("New list name", text: $newListName)
                } else {
                    Picker("Add to", selection: $selectedListID) {
                        ForEach(lists) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            Section {
                ForEach(recipe.ingredients) { line in
                    let have = selection.has(line.id)
                    Button {
                        selection.toggleHave(line.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.name)
                                    .strikethrough(have)
                                    .foregroundStyle(have ? Color.secondary : Color.primary)
                                AmountText(quantity: line.quantity, unit: line.unit)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("Have", systemImage: have ? "checkmark.square.fill" : "square")
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline)
                                .foregroundStyle(have ? RecipeBookTheme.success : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.name)
                    .accessibilityValue(have ? "Already have" : "Need to buy")
                    .accessibilityHint("Double-tap to toggle already have")
                    .accessibilityAddTraits(.isButton)
                }
            } header: {
                Text("Tick what you already have")
            } footer: {
                Text(needed.isEmpty
                     ? "You have everything — nothing to add."
                     : "\(needed.count) of \(recipe.ingredients.count) ingredients will be added.")
            }
            Section {
                RunningButton(title: needed.count == 1 ? "Add 1 Item" : "Add \(needed.count) Items",
                              systemImage: "cart.badge.plus", isRunning: runner.isRunning) {
                    let ids = needed.map(\.id)
                    let existing = lists.isEmpty ? nil : selectedListID
                    runner.run {
                        let listID: ShoppingListID
                        if let existing {
                            listID = existing
                        } else {
                            listID = try await service.createShoppingList(name: newName).id
                        }
                        _ = try await service.addRecipeIngredients(recipeID: recipe.id, ingredientIDs: ids, to: listID)
                        dismiss()
                    }
                }
                .disabled(!canSubmit)
            }
        }
    }
}

// MARK: - Editor

/// Read-only, selectable source text captured from an imported Reel. Nothing here is copied into
/// the recipe automatically.
@MainActor
struct SourceEvidenceSection: View {
    let text: String
    @State private var expanded = false

    private var isLong: Bool { text.count > 400 }

    var body: some View {
        Section {
            Text(text)
                .font(.callout)
                .lineLimit(expanded || !isLong ? nil : 8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Source text: \(text)")
            if isLong {
                Button(expanded ? "Show Less" : "Show All") { expanded.toggle() }
                    .accessibilityHint(expanded ? "Collapses the source text" : "Shows the full source text")
            }
        } header: {
            Label("Source evidence", systemImage: "text.quote")
        } footer: {
            Text("Caption, comments or transcript from the Reel. Select and copy what you need; amounts aren’t filled in for you.")
        }
    }
}

/// Manual recipe editor, also used to review imported drafts.
@MainActor
struct RecipeEditorView: View {
    let title: String
    let destinationBooks: [BookSummary]?
    let saveLabel: String
    let save: (RecipeDraft) async throws -> RecipeDetail
    let onSaved: (RecipeDetail) -> Void
    var showsCancel = true

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RecipeDraft
    @State private var initial: RecipeDraft
    @State private var issues: [DraftIssue] = []
    @State private var confirmDiscard = false
    @State private var runner = ActionRunner()
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedPreview: UIImage?
    @State private var processingPhoto = false
    @State private var photoError: String?

    init(title: String, draft: RecipeDraft, destinationBooks: [BookSummary]?, saveLabel: String,
         showsCancel: Bool = true,
         save: @escaping (RecipeDraft) async throws -> RecipeDetail,
         onSaved: @escaping (RecipeDetail) -> Void) {
        self.title = title
        self.destinationBooks = destinationBooks
        self.saveLabel = saveLabel
        self.showsCancel = showsCancel
        self.save = save
        self.onSaved = onSaved
        _draft = State(initialValue: draft)
        _initial = State(initialValue: draft)
    }

    var body: some View {
        Form {
            if !issues.isEmpty {
                Section {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(RecipeBookTheme.warning)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Fix before saving: " + issues.map(\.message).joined(separator: " "))
            }

            if let books = destinationBooks {
                Section {
                    Picker("Book", selection: $draft.bookID) {
                        Text("Choose a book").tag(BookID?.none)
                        ForEach(books) { Text($0.name).tag(Optional($0.id)) }
                    }
                } header: {
                    Text("Save to")
                } footer: {
                    if books.isEmpty { Text("Create a book in the Library first.") }
                }
            }

            if let evidence = draft.evidenceText?.trimmingCharacters(in: .whitespacesAndNewlines), !evidence.isEmpty {
                SourceEvidenceSection(text: evidence)
            }

            coverSection

            if let watch = ReelLink.watchURL(for: draft.sourceURL) {
                Section {
                    WatchOnInstagramButton(url: watch, compact: true)
                } header: {
                    Text("Source")
                } footer: {
                    Text("The link to the original Reel is kept with this recipe.")
                }
            }

            Section("Recipe") {
                TextField("Title", text: $draft.title, axis: .vertical)
                    .font(.system(.title3, design: .serif))
                Picker("Meal type", selection: $draft.mealStyle) {
                    Text("Not set").tag(MealStyle?.none)
                    ForEach(MealStyle.allCases, id: \.self) { style in
                        Label(style.title, systemImage: style.systemImage).tag(Optional(style))
                    }
                }
                LabeledContent("Servings") {
                    TextField("Optional", value: $draft.servings, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Total time (min)") {
                    TextField("Optional", value: $draft.totalMinutes, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                ForEach($draft.ingredients) { $line in
                    IngredientEditorRow(line: $line)
                }
                .onDelete { draft.ingredients.remove(atOffsets: $0) }
                .onMove { draft.ingredients.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    draft.ingredients.append(IngredientLine(name: ""))
                } label: {
                    Label("Add Ingredient", systemImage: "plus.circle")
                }
            } header: {
                Text("Ingredients")
            } footer: {
                Text("Leave the amount empty if it isn’t known. Metric units preferred.")
            }

            Section {
                ForEach($draft.steps) { $step in
                    let index = draft.steps.firstIndex { $0.id == step.id } ?? 0
                    let number = index + 1
                    let stepID = step.id
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(number)")
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(RecipeBookTheme.accent)
                            .frame(minWidth: 22)
                            .accessibilityHidden(true)
                        TextField("Describe step \(number)", text: $step.text, axis: .vertical)
                            .accessibilityLabel("Step \(number)")
                    }
                    .contextMenu {
                        Button("Move Up", systemImage: "arrow.up") { moveStep(stepID, by: -1) }
                            .disabled(index == 0)
                        Button("Move Down", systemImage: "arrow.down") { moveStep(stepID, by: 1) }
                            .disabled(index == draft.steps.count - 1)
                        Button("Delete Step", systemImage: "trash", role: .destructive) {
                            draft.steps.removeAll { $0.id == stepID }
                        }
                    }
                    .accessibilityAction(named: "Move up") { moveStep(stepID, by: -1) }
                    .accessibilityAction(named: "Move down") { moveStep(stepID, by: 1) }
                }
                .onDelete { draft.steps.remove(atOffsets: $0) }
                .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    draft.steps.append(RecipeStep(text: ""))
                } label: {
                    Label("Add Step", systemImage: "plus.circle")
                }
            } header: {
                HStack {
                    Text("Method")
                    Spacer()
                    EditButton().font(.caption).textCase(nil)
                }
            } footer: {
                Text("Tap Edit to drag steps into a new order, or touch and hold a step to move it up or down.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft != initial { confirmDiscard = true } else { runner.cancel(); dismiss() }
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if runner.isRunning {
                    ProgressView()
                } else {
                    Button(saveLabel, action: submit).fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled(draft != initial || runner.isRunning)
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { runner.cancel(); dismiss() }
        }
        .errorAlert($runner.errorMessage)
        .errorAlert($photoError)
        .disabled(runner.isRunning)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
    }

    private func moveStep(_ id: String, by offset: Int) {
        withAnimation { draft.steps = StepOrdering.move(draft.steps, id: id, by: offset) }
    }

    @ViewBuilder
    private var coverSection: some View {
        let hasCover: Bool = {
            switch draft.coverImageEdit {
            case .replace: return true
            case .remove: return false
            case .unchanged: return draft.coverImage != nil
            }
        }()
        Section {
            ZStack {
                if let pickedPreview, case .replace = draft.coverImageEdit {
                    Image(uiImage: pickedPreview).resizable().scaledToFill()
                } else if hasCover {
                    CoverImage(image: draft.coverImage, seed: draft.title, symbol: draft.mealStyle?.systemImage ?? "fork.knife")
                } else {
                    CoverPlaceholder(seed: draft.title.isEmpty ? "new" : draft.title,
                                     symbol: draft.mealStyle?.systemImage ?? "fork.knife")
                    Label("No photo yet", systemImage: "photo")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.35), in: Capsule())
                }
                if processingPhoto { ProgressView().tint(.white) }
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .accessibilityElement()
            .accessibilityLabel(hasCover ? "Cover photo selected" : "No cover photo")

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Label(hasCover ? "Choose Another Photo" : "Choose Photo", systemImage: "photo.on.rectangle")
            }
            .disabled(processingPhoto)
            if hasCover {
                Button("Remove Photo", systemImage: "trash", role: .destructive) {
                    photoItem = nil
                    pickedPreview = nil
                    draft.coverImageEdit = draft.coverImage == nil ? .unchanged : .remove
                }
            }
        } header: {
            Text("Cover photo")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        processingPhoto = true
        Task {
            defer { processingPhoto = false; photoItem = nil }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self),
                      let jpeg = await CoverPhotoEncoder.jpeg(from: raw) else {
                    photoError = "That photo couldn’t be read. Try a different one."
                    return
                }
                pickedPreview = UIImage(data: jpeg)
                draft.coverImageEdit = .replace(jpegData: jpeg)
            } catch {
                photoError = error.localizedDescription
            }
        }
    }

    private func submit() {
        var candidate = RecipeDraftRules.normalized(draft)
        for index in candidate.ingredients.indices {
            if let raw = candidate.ingredients[index].quantity,
               case .success(let normalized) = QuantityText.normalize(raw) {
                candidate.ingredients[index].quantity = normalized
            }
        }
        issues = RecipeDraftRules.issues(for: candidate)
        guard issues.isEmpty else { return }
        runner.run {
            let saved = try await save(candidate)
            initial = draft
            onSaved(saved)
            dismiss()
        }
    }
}

@MainActor
struct IngredientEditorRow: View {
    @Binding var line: IngredientLine

    private var quantity: Binding<String> {
        Binding(get: { line.quantity ?? "" },
                set: { newValue in
                    line.quantity = newValue.isEmpty ? nil : newValue
                    if !newValue.isEmpty { line.amountNeedsReview = false }
                })
    }

    private var unit: Binding<String> {
        Binding(get: { line.unit ?? "" }, set: { line.unit = $0.isEmpty ? nil : $0 })
    }

    private var preparation: Binding<String> {
        Binding(get: { line.preparation ?? "" }, set: { line.preparation = $0.isEmpty ? nil : $0 })
    }

    private var quantityIsInvalid: Bool {
        guard let q = line.quantity else { return false }
        if case .failure = QuantityText.normalize(q) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ingredient", text: $line.name)
            HStack {
                TextField("Amount", text: quantity)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: 110)
                    .foregroundStyle(quantityIsInvalid ? Color.red : Color.primary)
                    .accessibilityLabel("Amount for \(line.name.isEmpty ? "ingredient" : line.name)")
                Divider()
                TextField("Unit", text: unit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Menu {
                    ForEach(MetricUnits.common, id: \.self) { u in
                        Button(u) { line.unit = u }
                    }
                    Button("No unit") { line.unit = nil }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .accessibilityLabel("Choose unit")
                }
            }
            .font(.subheadline)
            TextField("Preparation (optional)", text: preparation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let original = line.originalText, !original.isEmpty {
                Text("Source: “\(original)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if line.amountNeedsReview {
                HStack(alignment: .firstTextBaseline) {
                    Label("Amount unclear in the source — enter it, or keep it unspecified.",
                          systemImage: "questionmark.diamond")
                        .font(.caption)
                        .foregroundStyle(RecipeBookTheme.warning)
                    Spacer()
                    Button("Keep Unspecified") { line.amountNeedsReview = false }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
