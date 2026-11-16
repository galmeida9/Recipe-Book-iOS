import Foundation

// Portable weekly-plan presentation rules. The planner domain stays the authority for generation,
// matching and shopping reconciliation; these only shape what the user asks for.

// MARK: - Dates

public enum PlanCalendar {
    /// ISO-8601 calendar: weeks start on Monday regardless of the user's locale.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public static func string(from date: Date) -> PlanDate { formatter().string(from: date) }

    public static func date(from planDate: PlanDate) -> Date? { formatter().date(from: planDate) }

    /// Monday of the week containing the user's local calendar day `date`.
    public static func weekStart(containing date: Date, in timeZone: TimeZone = .current) -> PlanDate {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        let day = calendar.date(from: parts) ?? date
        let weekday = calendar.component(.weekday, from: day) // 1 = Sunday … 7 = Saturday
        let offset = (weekday + 5) % 7 // days since Monday
        return string(from: calendar.date(byAdding: .day, value: -offset, to: day) ?? day)
    }

    /// Seven dates, Monday first. Returns an empty array for malformed input.
    public static func days(of weekStart: PlanDate) -> [PlanDate] {
        guard let start = date(from: weekStart) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map(string(from:))
    }

    public static func shift(_ weekStart: PlanDate, weeks: Int) -> PlanDate {
        guard let start = date(from: weekStart),
              let moved = calendar.date(byAdding: .day, value: 7 * weeks, to: start) else { return weekStart }
        return string(from: moved)
    }
}

// MARK: - Day rules

/// Index into a Monday-first week (0 = Monday … 6 = Sunday).
public enum Weekday: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    public var id: Int { rawValue }
    public var isWeekend: Bool { self == .saturday || self == .sunday }

    public var name: String {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][rawValue]
    }

    public var shortName: String { String(name.prefix(3)) }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How the user describes which days get which meal style. Every rule expands to exactly seven
/// explicit styles (Monday first) before it is sent to the planner.
public enum PlanDayRule: Equatable, Sendable {
    case wholeWeek(MealStyle)
    /// `nil` leaves that part of the week unplanned.
    case weekdaysAndWeekend(weekdays: MealStyle?, weekend: MealStyle?)
    /// Only the listed days are planned.
    case specificDays([Weekday: MealStyle])

    public var dayStyles: [MealStyle?] {
        Weekday.allCases.map { day in
            switch self {
            case .wholeWeek(let style): return style
            case let .weekdaysAndWeekend(weekdays, weekend): return day.isWeekend ? weekend : weekdays
            case .specificDays(let styles): return styles[day]
            }
        }
    }

    public var plannedDayCount: Int { dayStyles.compactMap { $0 }.count }
}

public enum PlanRules {
    /// Recipes offered for replacing a day: only the plan's book, recipes explicitly labelled with
    /// the day's style first, then the rest (alphabetical). The current recipe is excluded.
    public static func replacementCandidates(_ recipes: [RecipeSummary], for day: PlanDay) -> [RecipeSummary] {
        let others = recipes.filter { $0.id != day.slot?.recipeID }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard let style = day.mealStyle else { return others }
        return others.filter { $0.mealStyle == style } + others.filter { $0.mealStyle != style }
    }

    /// Recipes in the book labelled with each style (unlabelled recipes are counted separately).
    public static func styleCounts(_ recipes: [RecipeSummary]) -> (counts: [MealStyle: Int], unlabelled: Int) {
        var counts: [MealStyle: Int] = [:]
        var unlabelled = 0
        for recipe in recipes {
            if let style = recipe.mealStyle { counts[style, default: 0] += 1 } else { unlabelled += 1 }
        }
        return (counts, unlabelled)
    }

    public static func servingsText(_ servings: Int?) -> String {
        guard let servings else { return "Usual servings" }
        return servings == 1 ? "1 serving" : "\(servings) servings"
    }
}

// MARK: - Shopping sections

public extension ShoppingListRules {
    /// Items generated from the weekly plan, kept separate from what the user added.
    static func generated(_ items: [ShoppingItem]) -> [ShoppingItem] { ordered(items.filter(\.isGenerated)) }
    static func manual(_ items: [ShoppingItem]) -> [ShoppingItem] { ordered(items.filter { !$0.isGenerated }) }

    /// Row caption for a generated item. Names only the recipes that contributed to *this* item;
    /// without row-level contributions it stays neutral rather than crediting every planned recipe.
    static func generatedSourceText(_ provenance: PlanProvenance) -> String {
        let titles = provenance.recipeTitles.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !titles.isEmpty else { return "From this meal plan" }
        return "for " + ListFormatter.localizedString(byJoining: titles)
    }
}

// MARK: - Step ordering (accessible alternative to drag-to-reorder)

public enum StepOrdering {
    public static func move(_ steps: [RecipeStep], id: String, by offset: Int) -> [RecipeStep] {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return steps }
        let target = index + offset
        guard steps.indices.contains(target) else { return steps }
        var copy = steps
        copy.swapAt(index, target)
        return copy
    }
}

// MARK: - Instagram source link

public extension ReelLink {
    /// Validated canonical `https://www.instagram.com/reel/<id>/` link for "Watch on Instagram",
    /// or `nil` when the stored source is not an Instagram Reel.
    static func watchURL(for source: URL?) -> URL? {
        guard let source else { return nil }
        return extract(from: source.absoluteString)
    }
}
