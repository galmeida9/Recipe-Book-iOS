#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// Weekly cooking plan. The planner domain generates and reconciles; this UI only collects explicit
// choices (book, week, per-day meal style, shopping list) and shows the result.

enum PlanDateText {
    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = PlanCalendar.calendar
        formatter.timeZone = PlanCalendar.calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    static func string(_ date: PlanDate, template: String) -> String {
        guard let value = PlanCalendar.date(from: date) else { return date }
        return formatter(template).string(from: value)
    }

    static func weekTitle(_ weekStart: PlanDate, today: PlanDate = PlanCalendar.weekStart(containing: .now)) -> String {
        if weekStart == today { return "This week" }
        if weekStart == PlanCalendar.shift(today, weeks: 1) { return "Next week" }
        if weekStart == PlanCalendar.shift(today, weeks: -1) { return "Last week" }
        return "Week of " + string(weekStart, template: "dMMM")
    }

    static func range(_ weekStart: PlanDate) -> String {
        let end = PlanCalendar.shift(weekStart, weeks: 1)
        let sunday = PlanCalendar.days(of: weekStart).last ?? end
        return string(weekStart, template: "dMMM") + " – " + string(sunday, template: "dMMM")
    }
}

@MainActor
struct PlanView: View {
    @Environment(\.recipeBookService) private var service
    @AppStorage("RecipeBookUI.plan.bookID") private var storedBookID = ""
    @State private var books: LoadState<[BookSummary]> = .loading
    @State private var weekStart = PlanCalendar.weekStart(containing: .now)
    @State private var plan: LoadState<WeeklyPlan?> = .loading
    @State private var bookDetail: BookDetail?
    @State private var reloadBooks = 0
    @State private var reloadPlan = 0
    @State private var loadedPlanScope: PlanKey?
    @State private var showingGenerate = false
    @State private var dayToReplace: PlanDay?
    @State private var confirmDelete = false
    @State private var runner = ActionRunner()

    private var selectedBook: BookSummary? {
        guard let all = books.value, !all.isEmpty else { return nil }
        return all.first { $0.id == storedBookID } ?? all.first
    }

    var body: some View {
        NavigationStack {
            LoadingContent(state: books, retry: { reloadBooks += 1 }) { all in
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to plan from yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Plans are made from the recipes in one of your books. Create a book and add a few recipes first.")
                    }
                } else if let book = selectedBook {
                    content(book: book, books: all)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Plan")
            .navigationSubtitleIfAvailable(selectedBook.map { "From \($0.name)" })
            .recipeDestinations()
        }
        .task(id: reloadBooks) { await loadBooks() }
        .task(id: PlanKey(bookID: selectedBook?.id, weekStart: weekStart, reload: reloadPlan)) {
            // A different book or week starts fresh; a plain refresh keeps the plan on screen.
            let scope = PlanKey(bookID: selectedBook?.id, weekStart: weekStart, reload: 0)
            if scope != loadedPlanScope { plan = .loading }
            await loadPlan()
            if plan.value != nil { loadedPlanScope = scope }
        }
        .errorAlert($runner.errorMessage)
    }

    private var loadedWeek: WeeklyPlan? { plan.value ?? nil }

    private struct PlanKey: Hashable {
        let bookID: BookID?
        let weekStart: PlanDate
        let reload: Int
    }

    // MARK: Content

    @ViewBuilder
    private func content(book: BookSummary, books all: [BookSummary]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controls(book: book, books: all)
                switch plan {
                case .loading:
                    ProgressView("Loading plan…").frame(maxWidth: .infinity, minHeight: 200)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t load this week", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { reloadPlan += 1 }.buttonStyle(.borderedProminent)
                    }
                case .loaded(.none):
                    emptyWeek(book)
                case .loaded(.some(let week)):
                    planContent(week)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await loadPlan() }
        .toolbar {
            if let week = loadedWeek {
                ToolbarItem(placement: .primaryAction) {
                    Button("Regenerate", systemImage: "wand.and.stars") { showingGenerate = true }
                        .disabled(runner.isRunning)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Delete Plan…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(runner.isRunning)
                        .id(week.version)
                }
            }
        }
        .sheet(isPresented: $showingGenerate) {
            GeneratePlanSheet(book: book, weekStart: weekStart, recipes: bookDetail?.recipes ?? [],
                              existing: loadedWeek) { generated in
                plan = .loaded(generated)
            }
        }
        .sheet(item: $dayToReplace) { day in
            if let week = loadedWeek {
                ReplaceMealSheet(plan: week, day: day, recipes: bookDetail?.recipes ?? []) { updated in
                    plan = .loaded(updated)
                }
            }
        }
        .confirmationDialog("Delete this week’s plan?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Plan", role: .destructive) {
                guard let week = loadedWeek else { return }
                runner.run {
                    try await service.deleteWeek(bookID: week.bookID, weekStart: week.weekStart, planVersion: week.version)
                    plan = .loaded(.none)
                }
            }
        } message: {
            Text("Its automatically added shopping items are removed too. Items you added yourself stay.")
        }
    }

    private func controls(book: BookSummary, books all: [BookSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                Picker("Plan from", selection: Binding(get: { book.id }, set: { storedBookID = $0 })) {
                    ForEach(all) { Text($0.name).tag($0.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    CoverImage(image: book.coverImage, seed: book.id, symbol: "book.closed.fill")
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Planning from").font(.caption).foregroundStyle(.secondary)
                        Text(book.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel("Planning from \(book.name)")
            .accessibilityHint("Choose which book’s recipes the plan uses")

            HStack {
                Button { weekStart = PlanCalendar.shift(weekStart, weeks: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous week")
                Spacer()
                VStack(spacing: 2) {
                    Text(PlanDateText.weekTitle(weekStart)).font(.title3.weight(.semibold))
                    Text(PlanDateText.range(weekStart)).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { weekStart = PlanCalendar.shift(weekStart, weeks: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next week")
            }
        }
    }

    private func emptyWeek(_ book: BookSummary) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(RecipeBookTheme.accent)
                .accessibilityHidden(true)
            Text("No plan for this week").font(.title3.weight(.semibold))
            Text("Choose which days to cook and how much effort each one gets. Recipes come from “\(book.name)”, and their ingredients are added to your shopping list automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showingGenerate = true
            } label: {
                Label("Create Plan", systemImage: "wand.and.stars").frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private func planContent(_ week: WeeklyPlan) -> some View {
        if !week.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(week.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(RecipeBookTheme.warning)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecipeBookTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        ForEach(week.days) { day in
            PlanDayCard(day: day, isBusy: runner.isRunning,
                        onReplace: { dayToReplace = day },
                        onClear: { clear(day, in: week) })
        }
        Label("Ingredients for planned meals are added to your shopping list under “Automatic”. Changing the plan updates them.",
              systemImage: "cart.badge.plus")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func clear(_ day: PlanDay, in week: WeeklyPlan) {
        runner.run {
            plan = .loaded(try await service.replacePlanDay(bookID: week.bookID, weekStart: week.weekStart, date: day.date,
                                                            replacement: nil, planVersion: week.version))
        }
    }

    // MARK: Loading

    private func loadBooks() async {
        do {
            books = .loaded(try await service.books())
        } catch let error where !error.isCancellation {
            if books.value == nil {
                books = .failed(error.localizedDescription)
            } else {
                runner.errorMessage = error.localizedDescription
            }
        } catch {}
    }

    private func loadPlan() async {
        guard let book = selectedBook else { return }
        do {
            async let week = service.readWeek(bookID: book.id, weekStart: weekStart)
            async let detail = service.book(id: book.id)
            plan = .loaded(try await week)
            bookDetail = try? await detail
        } catch let error where !error.isCancellation {
            if plan.value == nil {
                plan = .failed(error.localizedDescription)
            } else {
                runner.errorMessage = error.localizedDescription
            }
        } catch {}
    }
}

/// One day of the plan: image-led when a recipe is planned.
@MainActor
private struct PlanDayCard: View {
    let day: PlanDay
    let isBusy: Bool
    let onReplace: () -> Void
    let onClear: () -> Void

    var body: some View {
        if day.mealStyle == nil && day.slot == nil {
            HStack {
                dayLabel
                Spacer()
                Text("Not planned").font(.subheadline).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 8) {
                    if let slot = day.slot {
                        if let recipe = slot.recipe {
                            Text(recipe.title)
                                .font(.system(.title3, design: .serif).weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Label("This recipe is no longer available", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(RecipeBookTheme.warning)
                        }
                        HStack(spacing: 14) {
                            MetaLabel(text: PlanRules.servingsText(slot.servings), systemImage: "person.2")
                            if let minutes = slot.recipe?.totalMinutes {
                                MetaLabel(text: formattedMinutes(minutes), systemImage: "clock")
                            }
                        }
                    } else if let style = day.mealStyle {
                        Text("No \(style.title.lowercased()) recipe found")
                            .font(.headline)
                        Text("Label more recipes in this book as “\(style.title)”, or pick one yourself.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if let slot = day.slot, slot.recipe != nil {
                            NavigationLink(value: RecipeRoute(id: slot.recipeID, title: slot.recipe?.title ?? "Recipe")) {
                                Label("Open", systemImage: "book")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(action: onReplace) {
                            Label(day.slot == nil ? "Choose Recipe" : "Replace", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Menu {
                            Button("Choose Another Recipe", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                            if day.slot != nil {
                                Button("Clear Day", systemImage: "xmark.circle", role: .destructive, action: onClear)
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("More for \(dayName)")
                    }
                    .disabled(isBusy)
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(dayName)
        }
    }

    private var dayName: String { PlanDateText.string(day.date, template: "EEEEdMMMM") }

    private var dayLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PlanDateText.string(day.date, template: "EEEE")).font(.headline)
            Text(PlanDateText.string(day.date, template: "dMMM")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(image: day.slot?.recipe?.coverImage, seed: day.slot?.recipeID ?? day.date,
                       symbol: day.mealStyle?.systemImage ?? "fork.knife")
                .frame(height: 150)
                .frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .accessibilityHidden(true)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(PlanDateText.string(day.date, template: "EEEE")).font(.headline)
                    Text(PlanDateText.string(day.date, template: "dMMM")).font(.caption)
                }
                .foregroundStyle(.white)
                Spacer()
                if let style = day.mealStyle { MealStyleBadge(style: style, prominent: true) }
            }
            .padding(12)
        }
        .frame(height: 150)
        .clipped()
    }
}

// MARK: - Generate

@MainActor
struct GeneratePlanSheet: View {
    let book: BookSummary
    let weekStart: PlanDate
    let recipes: [RecipeSummary]
    let existing: WeeklyPlan?
    let onGenerated: (WeeklyPlan) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case wholeWeek, split, specific
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wholeWeek: return "Whole week"
            case .split: return "Weekdays & weekend"
            case .specific: return "Specific days"
            }
        }
    }

    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .split
    @State private var wholeWeekStyle: MealStyle = .simple
    @State private var weekdayStyle: MealStyle? = .simple
    @State private var weekendStyle: MealStyle? = .full
    @State private var specific: [Weekday: MealStyle] = [:]
    @State private var lists: LoadState<[ShoppingListSummary]> = .loading
    @State private var listID: ShoppingListID?
    @State private var runner = ActionRunner()

    init(book: BookSummary, weekStart: PlanDate, recipes: [RecipeSummary], existing: WeeklyPlan?,
         onGenerated: @escaping (WeeklyPlan) -> Void) {
        self.book = book
        self.weekStart = weekStart
        self.recipes = recipes
        self.existing = existing
        self.onGenerated = onGenerated
        if let existing {
            var styles: [Weekday: MealStyle] = [:]
            for (index, day) in existing.days.enumerated() {
                if let style = day.mealStyle, let weekday = Weekday(rawValue: index) { styles[weekday] = style }
            }
            _mode = State(initialValue: .specific)
            _specific = State(initialValue: styles)
            _listID = State(initialValue: existing.shoppingListID)
        }
    }

    private var rule: PlanDayRule {
        switch mode {
        case .wholeWeek: return .wholeWeek(wholeWeekStyle)
        case .split: return .weekdaysAndWeekend(weekdays: weekdayStyle, weekend: weekendStyle)
        case .specific: return .specificDays(specific)
        }
    }

    private var newListName: String { "Week of " + PlanDateText.string(weekStart, template: "dMMM") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Plan", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch mode {
                case .wholeWeek:
                    Section("Every day") {
                        MealStylePicker(selection: Binding(get: { wholeWeekStyle }, set: { if let s = $0 { wholeWeekStyle = s } }),
                                        allowsNone: false)
                    }
                case .split:
                    Section("Monday to Friday") {
                        MealStylePicker(selection: $weekdayStyle, allowsNone: true)
                    }
                    Section("Saturday and Sunday") {
                        MealStylePicker(selection: $weekendStyle, allowsNone: true)
                    }
                case .specific:
                    Section {
                        ForEach(Weekday.allCases) { day in
                            SpecificDayRow(day: day, style: Binding(get: { specific[day] }, set: { specific[day] = $0 }))
                        }
                    } header: {
                        Text("Days to cook")
                    } footer: {
                        Text("Turn on the days you want to cook and choose a meal type for each.")
                    }
                }

                Section {
                    WeekStylePreview(dayStyles: rule.dayStyles)
                } header: {
                    Text(rule.plannedDayCount == 1 ? "1 day planned" : "\(rule.plannedDayCount) days planned")
                } footer: {
                    Text(inventoryFooter)
                }

                Section {
                    switch lists {
                    case .loading:
                        ProgressView()
                    case .failed(let message):
                        Text(message).foregroundStyle(.secondary)
                    case .loaded(let all):
                        Picker("Add ingredients to", selection: $listID) {
                            Text("New list: \(newListName)").tag(ShoppingListID?.none)
                            ForEach(all) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                } header: {
                    Text("Shopping")
                } footer: {
                    Text("Ingredients are added automatically, in their own “Automatic” section, and kept up to date when you change the plan.")
                }
            }
            .navigationTitle(existing == nil ? "Create Plan" : "Regenerate Plan")
            .navigationSubtitleIfAvailable("\(book.name) · \(PlanDateText.range(weekStart))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancel(); dismiss() }
                }
            }
            .bottomControlBar {
                RunningButton(title: existing == nil ? "Generate Plan" : "Regenerate Plan", systemImage: "wand.and.stars",
                              isRunning: runner.isRunning, action: generate)
                    .floatingPrimaryButtonStyle()
                    .controlSize(.large)
                    .disabled(rule.plannedDayCount == 0 || lists.value == nil)
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .task {
            do {
                lists = .loaded(try await service.shoppingLists())
            } catch let error where !error.isCancellation {
                lists = .failed(error.localizedDescription)
            } catch {}
        }
        .errorAlert($runner.errorMessage)
    }

    private var inventoryFooter: String {
        guard !recipes.isEmpty else { return "Recipes are chosen from “\(book.name)”." }
        let (counts, unlabelled) = PlanRules.styleCounts(recipes)
        var parts = MealStyle.allCases.map { "\(counts[$0, default: 0]) \($0.title.lowercased())" }
        if unlabelled > 0 { parts.append("\(unlabelled) without a meal type") }
        return "“\(book.name)” has " + parts.joined(separator: ", ") + ". Set a recipe’s meal type in its editor."
    }

    private func generate() {
        let styles = rule.dayStyles
        let existingList = listID
        let name = newListName
        let expected = existing?.version
        runner.run {
            let targetList: ShoppingListID
            if let existingList {
                targetList = existingList
            } else {
                targetList = try await service.createShoppingList(name: name).id
                listID = targetList
            }
            let plan = try await service.generateWeek(bookID: book.id, weekStart: weekStart, dayStyles: styles,
                                                      listID: targetList, expectedVersion: expected)
            onGenerated(plan)
            dismiss()
        }
    }
}

/// Three explicit meal-type choices (plus "Off" when allowed), as large accessible rows.
@MainActor
struct MealStylePicker: View {
    @Binding var selection: MealStyle?
    let allowsNone: Bool

    var body: some View {
        ForEach(MealStyle.allCases) { style in
            choice(title: style.title, subtitle: subtitle(style), systemImage: style.systemImage, value: style)
        }
        if allowsNone {
            choice(title: "Don’t plan", subtitle: nil, systemImage: "moon.zzz", value: nil)
        }
    }

    private func subtitle(_ style: MealStyle) -> String {
        switch style {
        case .simple: return "Recipes you’ve labelled simple"
        case .complicated: return "Recipes you’ve labelled more complicated"
        case .full: return "Recipes you’ve labelled as a full meal"
        }
    }

    private func choice(title: String, subtitle: String?, systemImage: String, value: MealStyle?) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 28)
                    .foregroundStyle(RecipeBookTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(RecipeBookTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

@MainActor
private struct SpecificDayRow: View {
    let day: Weekday
    @Binding var style: MealStyle?

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { style != nil }, set: { style = $0 ? (style ?? .simple) : nil })) {
                Text(day.name)
            }
            .fixedSize()
            Spacer()
            if style != nil {
                Picker("Meal type for \(day.name)", selection: Binding(get: { style ?? .simple }, set: { style = $0 })) {
                    ForEach(MealStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }
}

/// Seven-column summary of what will be requested.
@MainActor
private struct WeekStylePreview: View {
    let dayStyles: [MealStyle?]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Weekday.allCases) { day in
                        HStack {
                            Text(day.name)
                            Spacer()
                            Text(dayStyles[day.rawValue]?.title ?? "Not planned").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(Weekday.allCases) { day in
                        let style = dayStyles[day.rawValue]
                        VStack(spacing: 6) {
                            Text(day.shortName).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            ZStack {
                                Circle().fill(style == nil ? Color(.tertiarySystemFill) : RecipeBookTheme.accent.opacity(0.16))
                                Image(systemName: style?.systemImage ?? "minus")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(style == nil ? Color.secondary : RecipeBookTheme.accent)
                            }
                            .frame(width: 34, height: 34)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.name): \(style?.title ?? "not planned")")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Replace

@MainActor
struct ReplaceMealSheet: View {
    let plan: WeeklyPlan
    let day: PlanDay
    let recipes: [RecipeSummary]
    let onReplaced: (WeeklyPlan) -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var choosing: RecipeID?
    @State private var runner = ActionRunner()

    var body: some View {
        let candidates = PlanRules.replacementCandidates(recipes, for: day)
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        let matching = candidates.filter { day.mealStyle != nil && $0.mealStyle == day.mealStyle }
        let others = candidates.filter { !(day.mealStyle != nil && $0.mealStyle == day.mealStyle) }
        NavigationStack {
            List {
                if recipes.isEmpty {
                    ContentUnavailableView("No other recipes in this book", systemImage: "fork.knife")
                } else if candidates.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                if let style = day.mealStyle, !matching.isEmpty {
                    Section("Labelled \(style.title.lowercased())") { rows(matching) }
                }
                if !others.isEmpty {
                    Section(day.mealStyle == nil || matching.isEmpty ? "Recipes in this book" : "Other recipes") { rows(others) }
                }
            }
            .searchable(text: $search, prompt: "Search this book")
            .navigationTitle("Replace \(PlanDateText.string(day.date, template: "EEEE"))")
            .navigationSubtitleIfAvailable(day.slot?.recipe.map { "Currently: \($0.title)" })
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

    private func rows(_ recipes: [RecipeSummary]) -> some View {
        ForEach(recipes) { recipe in
            Button {
                choose(recipe)
            } label: {
                HStack(spacing: 12) {
                    RecipeThumbnail(recipe: recipe, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recipe.title).font(.system(.body, design: .serif).weight(.medium)).foregroundStyle(.primary)
                        HStack(spacing: 8) {
                            if let style = recipe.mealStyle { MealStyleBadge(style: style) }
                            if let minutes = recipe.totalMinutes {
                                Text(formattedMinutes(minutes)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if choosing == recipe.id && runner.isRunning { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(runner.isRunning)
            .accessibilityHint("Plans this recipe instead")
        }
    }

    private func choose(_ recipe: RecipeSummary) {
        choosing = recipe.id
        // Use the replacement recipe's own normal yield; nil means unknown, never an invented 1.
        let replacement = PlanReplacement(recipeID: recipe.id, recipeVersion: recipe.version, servings: recipe.servings)
        runner.run {
            let updated = try await service.replacePlanDay(bookID: plan.bookID, weekStart: plan.weekStart, date: day.date,
                                                           replacement: replacement, planVersion: plan.version)
            onReplaced(updated)
            dismiss()
        }
    }
}
#endif
