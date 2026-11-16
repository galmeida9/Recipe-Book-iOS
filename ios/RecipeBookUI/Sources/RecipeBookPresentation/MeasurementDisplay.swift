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
        KnownUnit(symbol: "pc", kind: .count, baseFactor: nil, system: nil,
                  aliases: ["pcs", "piece", "pieces"]),
        KnownUnit(symbol: "clove", kind: .count, baseFactor: nil, system: nil, aliases: ["cloves"]),
        KnownUnit(symbol: "slice", kind: .count, baseFactor: nil, system: nil, aliases: ["slices"]),
        KnownUnit(symbol: "can", kind: .count, baseFactor: nil, system: nil, aliases: ["cans", "tin", "tins"]),
        KnownUnit(symbol: "bunch", kind: .count, baseFactor: nil, system: nil, aliases: ["bunches"]),
        KnownUnit(symbol: "handful", kind: .count, baseFactor: nil, system: nil, aliases: ["handfuls"]),
        KnownUnit(symbol: "pinch", kind: .count, baseFactor: nil, system: nil, aliases: ["pinches"]),
    ]
    // Cups, fluid ounces, pints and quarts are deliberately absent: US, UK and metric sizes differ,
    // so they stay as written and are never converted or treated as weight.

    /// Matches a stored unit by symbol or alias, ignoring case, spacing and a trailing period.
    public static func knownUnit(for raw: String?) -> KnownUnit? {
        guard let key = raw?.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")), !key.isEmpty else { return nil }
        return units.first { $0.symbol == key || $0.aliases.contains(key) }
    }

    /// Amount text for the viewer's system. Weights and metric volumes in the other system are
    /// converted and prefixed with "≈"; everything else is shown exactly as stored.
    public static func display(quantity: String?, unit: String?, system: UnitSystem, locale: Locale = .current) -> String? {
        guard let written = QuantityText.display(quantity: quantity, unit: unit) else { return nil }
        guard let converted = convert(quantity: quantity, unit: unit, to: system.resolved(for: locale)) else {
            return written
        }
        return "≈ \(converted)"
    }

    /// Converted amount without the "≈" marker, or `nil` when no conversion applies.
    static func convert(quantity: String?, unit: String?, to target: UnitSystem) -> String? {
        guard let q = quantity?.trimmingCharacters(in: .whitespaces), !q.isEmpty,
              let value = QuantityText.parse(q),
              let known = knownUnit(for: unit),
              let factor = known.baseFactor,
              let source = known.system, source != target else { return nil }
        let base = value * factor
        switch (known.kind, target) {
        case (.weight, .metric):
            return base >= 1000 ? "\(format(base / 1000, scale: 2)) kg" : "\(format(base, scale: base < 10 ? 1 : 0)) g"
        case (.weight, .imperial):
            let ounces = base / gramsPerOunce
            return ounces >= 16 ? "\(format(ounces / 16, scale: 2)) lb" : "\(format(ounces, scale: 1)) oz"
        default:
            // Imperial volumes are ambiguous between US and UK, so metric volumes stay as written.
            return nil
        }
    }

    private static func format(_ value: Decimal, scale: Int) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, scale, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
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

    /// Units offered in the ingredient editor: metric and count units, plus the stored unit when
    /// it is anything else (an imperial unit, an alias like "grams", or unknown text).
    public static func pickerOptions(current: String?) -> PickerOptions {
        let offered = units.filter { $0.system != .imperial }
        let groups = UnitKind.allCases.map { kind in
            UnitGroup(kind: kind, units: offered.filter { $0.kind == kind })
        }
        let trimmed = current?.trimmingCharacters(in: .whitespaces)
        let retained = (trimmed?.isEmpty ?? true) || offered.contains { $0.symbol == trimmed } ? nil : trimmed
        return PickerOptions(groups: groups, retainedSourceUnit: retained)
    }
}
