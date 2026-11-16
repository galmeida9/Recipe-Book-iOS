import Foundation

// Viewer-side measurement display. Stored quantities and units are never rewritten: conversion
// happens only when text is shown, and only between units with exact, unambiguous factors.

/// The viewer's preferred measurement system. A local preference, not recipe or account data.
public enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case metric
    case imperial

    public static let storageKey = "recipeBook.unitSystem"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }

    /// `.automatic` follows the region's measurement system: only US customary regions get
    /// imperial, so Norway, the UK and everywhere else default to metric.
    public func resolved(for locale: Locale) -> UnitSystem {
        guard self == .automatic else { return self }
        return locale.measurementSystem == .us ? .imperial : .metric
    }
}

public enum UnitKind: String, CaseIterable, Sendable {
    case weight
    case volume
    case count

    public var title: String {
        switch self {
        case .weight: return "Weight"
        case .volume: return "Volume"
        case .count: return "Count"
        }
    }
}

/// A cooking unit the app recognises. `symbol` is the value stored when picked in the editor.
public struct KnownUnit: Equatable, Hashable, Sendable, Identifiable {
    public let symbol: String
    public let kind: UnitKind
    /// Exact grams or millilitres per unit; `nil` when the unit must never be converted.
    let baseFactor: Decimal?
    let system: UnitSystem?
    let aliases: [String]

    public var id: String { symbol }
}

public enum MeasurementDisplay {
    private static let gramsPerOunce = Decimal(string: "28.349523125")!
    private static let millilitresPerUSFluidOunce = Decimal(string: "29.5735295625")!
    private static let millilitresPerUSCup = Decimal(string: "236.5882365")!

    public static let units: [KnownUnit] = [
        KnownUnit(symbol: "g", kind: .weight, baseFactor: 1, system: .metric,
                  aliases: ["gram", "grams", "gr"]),
        KnownUnit(symbol: "kg", kind: .weight, baseFactor: 1000, system: .metric,
                  aliases: ["kilogram", "kilograms", "kilo", "kilos"]),
        KnownUnit(symbol: "oz", kind: .weight, baseFactor: gramsPerOunce, system: .imperial,
                  aliases: ["ounce", "ounces"]),
        KnownUnit(symbol: "lb", kind: .weight, baseFactor: Decimal(string: "453.59237"), system: .imperial,
                  aliases: ["lbs", "pound", "pounds"]),
        KnownUnit(symbol: "ml", kind: .volume, baseFactor: 1, system: .metric,
                  aliases: ["milliliter", "milliliters", "millilitre", "millilitres"]),
        KnownUnit(symbol: "cl", kind: .volume, baseFactor: 10, system: .metric,
                  aliases: ["centiliter", "centiliters", "centilitre", "centilitres"]),
        KnownUnit(symbol: "dl", kind: .volume, baseFactor: 100, system: .metric,
                  aliases: ["deciliter", "deciliters", "decilitre", "decilitres"]),
        KnownUnit(symbol: "l", kind: .volume, baseFactor: 1000, system: .metric,
                  aliases: ["liter", "liters", "litre", "litres"]),
        // Spoons read the same in every system; they are shown as written.
        KnownUnit(symbol: "tsp", kind: .volume, baseFactor: nil, system: nil,
                  aliases: ["teaspoon", "teaspoons"]),
        KnownUnit(symbol: "tbsp", kind: .volume, baseFactor: nil, system: nil,
                  aliases: ["tablespoon", "tablespoons", "tbs"]),
        // Imperial volumes only when the source names the standard: US and UK sizes differ.
        KnownUnit(symbol: "US fl oz", kind: .volume, baseFactor: millilitresPerUSFluidOunce, system: .imperial,
                  aliases: ["us fluid ounce", "us fluid ounces", "fl oz (us)"]),
        KnownUnit(symbol: "US cup", kind: .volume, baseFactor: millilitresPerUSCup, system: .imperial,
                  aliases: ["us cups", "cup (us)", "cups (us)"]),
        KnownUnit(symbol: "US pint", kind: .volume, baseFactor: Decimal(string: "473.176473"), system: .imperial,
                  aliases: ["us pints", "us pt", "pint (us)", "pints (us)"]),
        KnownUnit(symbol: "UK fl oz", kind: .volume, baseFactor: Decimal(string: "28.4130625"), system: .imperial,
                  aliases: ["uk fluid ounce", "uk fluid ounces", "fl oz (uk)", "imperial fl oz"]),
        KnownUnit(symbol: "UK pint", kind: .volume, baseFactor: Decimal(string: "568.26125"), system: .imperial,
                  aliases: ["uk pints", "uk pt", "pint (uk)", "pints (uk)", "imperial pint", "imperial pints"]),
        KnownUnit(symbol: "pc", kind: .count, baseFactor: nil, system: nil,
                  aliases: ["pcs", "piece", "pieces"]),
        KnownUnit(symbol: "clove", kind: .count, baseFactor: nil, system: nil, aliases: ["cloves"]),
        KnownUnit(symbol: "slice", kind: .count, baseFactor: nil, system: nil, aliases: ["slices"]),
        KnownUnit(symbol: "can", kind: .count, baseFactor: nil, system: nil, aliases: ["cans", "tin", "tins"]),
        KnownUnit(symbol: "bunch", kind: .count, baseFactor: nil, system: nil, aliases: ["bunches"]),
        KnownUnit(symbol: "handful", kind: .count, baseFactor: nil, system: nil, aliases: ["handfuls"]),
        KnownUnit(symbol: "pinch", kind: .count, baseFactor: nil, system: nil, aliases: ["pinches"]),
    ]
    // Plain "cup", "fl oz", "pint" and "quart" are deliberately unknown: without a named standard
    // they stay as written and are never converted or treated as weight.

    /// Matches a stored unit by symbol or alias, ignoring case, spacing and a trailing period.
    public static func knownUnit(for raw: String?) -> KnownUnit? {
        guard let key = raw?.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")), !key.isEmpty else { return nil }
        return units.first { $0.symbol.lowercased() == key || $0.aliases.contains(key) }
    }

    /// Amount text for the viewer's system. Weights and standard-named volumes in the other system
    /// are converted, formatted for `locale` and prefixed with "≈"; everything else is shown
    /// exactly as stored.
    public static func display(quantity: String?, unit: String?, system: UnitSystem, locale: Locale = .current) -> String? {
        guard let written = QuantityText.display(quantity: quantity, unit: unit) else { return nil }
        guard let converted = convert(quantity: quantity, unit: unit, to: system.resolved(for: locale), locale: locale) else {
            return written
        }
        return "≈ \(converted)"
    }

    /// Converted amount without the "≈" marker, or `nil` when no conversion applies.
    static func convert(quantity: String?, unit: String?, to target: UnitSystem, locale: Locale) -> String? {
        guard let q = quantity?.trimmingCharacters(in: .whitespaces), !q.isEmpty,
              let value = QuantityText.parse(q),
              let known = knownUnit(for: unit),
              let factor = known.baseFactor,
              let source = known.system, source != target else { return nil }
        let base = value * factor
        func number(_ v: Decimal, _ scale: Int) -> String { format(v, scale: scale, locale: locale) }
        switch (known.kind, target) {
        case (.weight, .metric):
            return base >= 1000 ? "\(number(base / 1000, 2)) kg" : "\(number(base, base < 10 ? 1 : 0)) g"
        case (.weight, .imperial):
            let ounces = base / gramsPerOunce
            return ounces >= 16 ? "\(number(ounces / 16, 2)) lb" : "\(number(ounces, 1)) oz"
        case (.volume, .metric):
            return base >= 1000 ? "\(number(base / 1000, 2)) l" : "\(number(base, base < 10 ? 1 : 0)) ml"
        case (.volume, .imperial):
            // Metric volumes are shown in US measures, always labelled as such.
            if base >= millilitresPerUSCup {
                let cups = number(base / millilitresPerUSCup, 2)
                return cups == number(1, 0) ? "\(cups) US cup" : "\(cups) US cups"
            }
            return "\(number(base / millilitresPerUSFluidOunce, 1)) US fl oz"
        default:
            return nil
        }
    }

    private static func format(_ value: Decimal, scale: Int, locale: Locale) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, scale, .plain)
        return rounded.formatted(Decimal.FormatStyle(locale: locale)
            .precision(.fractionLength(0...scale))
            .grouping(.never))
    }

    // MARK: - Temperatures in step text

    private static let temperaturePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.,])(-?\d{1,3}(?:[.,]\d+)?)\s?°\s?([CF])(?!\p{L})"#)

    /// Step text for display: every explicit "°C"/"°F" temperature in the other system gets the
    /// converted value appended, e.g. "350°F (≈ 177 °C)". The stored text is never changed, and
    /// numbers without an explicit degree sign are left alone.
    public static func stepText(_ text: String, system: UnitSystem, locale: Locale = .current) -> String {
        let target = system.resolved(for: locale)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in temperaturePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            let scale = ns.substring(with: match.range(at: 2))
            guard let value = Double(digits) else { continue }
            let converted: String
            switch (scale, target) {
            case ("F", .metric): converted = "\(Int(((value - 32) * 5 / 9).rounded())) °C"
            case ("C", .imperial): converted = "\(Int((value * 9 / 5 + 32).rounded())) °F"
            default: continue
            }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "\(token) (≈ \(converted))"
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    // MARK: - Editor picker

    public struct UnitGroup: Equatable, Sendable, Identifiable {
        public let kind: UnitKind
        public let units: [KnownUnit]
        public var id: UnitKind { kind }
    }

    public struct PickerOptions: Equatable, Sendable {
        public let groups: [UnitGroup]
        /// The stored unit, kept as its own choice when it is not one of the picker symbols, so
        /// opening the editor never silently changes it.
        public let retainedSourceUnit: String?
    }

    /// Units offered in the ingredient editor: every known unit, metric first, plus the stored
    /// unit when it is anything else (an alias like "grams", a plain "cup", or unknown text).
    /// Picking only changes the unit; the amount is never converted.
    public static func pickerOptions(current: String?) -> PickerOptions {
        let offered = units
        let groups = UnitKind.allCases.map { kind in
            UnitGroup(kind: kind, units: offered.filter { $0.kind == kind })
        }
        let trimmed = current?.trimmingCharacters(in: .whitespaces)
        let retained = (trimmed?.isEmpty ?? true) || offered.contains { $0.symbol == trimmed } ? nil : trimmed
        return PickerOptions(groups: groups, retainedSourceUnit: retained)
    }
}
