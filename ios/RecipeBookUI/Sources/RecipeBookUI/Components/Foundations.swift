#if os(iOS)
import SwiftUI
import UIKit
import RecipeBookPresentation

// MARK: - Theme

/// Recipe Book's visual language: warm paprika accent on system backgrounds, serif display
/// type for titles (recipe-book feel) and SF for everything functional. All colours adapt to
/// dark mode and keep ≥ 4.5:1 contrast against system backgrounds for text use.
public enum RecipeBookTheme {
    public static let accent = Color(light: (0.66, 0.25, 0.14), dark: (0.97, 0.60, 0.47))
    static let warning = Color(light: (0.60, 0.36, 0.00), dark: (1.00, 0.78, 0.36))
    static let success = Color(light: (0.13, 0.45, 0.27), dark: (0.50, 0.85, 0.62))

    /// Accessible cover tints for books, picked deterministically from the book id.
    static let coverTints: [Color] = [
        Color(light: (0.66, 0.25, 0.14), dark: (0.97, 0.60, 0.47)), // paprika
        Color(light: (0.16, 0.42, 0.33), dark: (0.52, 0.82, 0.68)), // herb
        Color(light: (0.20, 0.33, 0.56), dark: (0.58, 0.72, 0.95)), // ink
        Color(light: (0.52, 0.28, 0.50), dark: (0.85, 0.65, 0.84)), // plum
        Color(light: (0.55, 0.40, 0.08), dark: (0.93, 0.78, 0.45)), // mustard
    ]

    static func tint(for id: String) -> Color {
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return coverTints[abs(sum) % coverTints.count]
    }
}

extension Color {
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension View {
    /// Serif display style used for book and recipe titles.
    func displayTitle(_ style: Font.TextStyle = .largeTitle) -> some View {
        font(.system(style, design: .serif).weight(.semibold))
    }
}

// MARK: - Service injection

private struct RecipeBookServiceKey: EnvironmentKey {
    static let defaultValue: any RecipeBookService = UnconfiguredRecipeBookService()
}

public extension EnvironmentValues {
    var recipeBookService: any RecipeBookService {
        get { self[RecipeBookServiceKey.self] }
        set { self[RecipeBookServiceKey.self] = newValue }
    }
}

// MARK: - Async state

enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }
}

extension Error {
    /// Cancellation is a normal outcome of leaving a screen, not an error to show.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        return false
    }
}

/// Runs one user-initiated async action at a time: prevents double submits, surfaces errors
/// and supports cancellation.
@MainActor
@Observable
final class ActionRunner {
    private(set) var isRunning = false
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated init() {}

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                try await operation()
            } catch let error where error.isCancellation || Task.isCancelled {
                // Leaving the screen or tapping Cancel is not a failure.
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isRunning = false
        }
    }

    func cancel() { task?.cancel() }
}

/// Loads `Value` and renders loading / failure / content states consistently.
struct LoadingContent<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let value):
            content(value)
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Something went wrong",
              isPresented: Binding(get: { message.wrappedValue != nil },
                                   set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// Primary button that shows progress and disables itself while its action runs.
@MainActor
struct RunningButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if isRunning { ProgressView() }
                if let systemImage, !isRunning {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(isRunning)
        .accessibilityLabel(isRunning ? "\(title), in progress" : title)
    }
}

// MARK: - Navigation

struct RecipeRoute: Hashable {
    let id: RecipeID
    let title: String
}

extension View {
    func recipeDestinations() -> some View {
        navigationDestination(for: RecipeRoute.self) { RecipeDetailView(route: $0) }
            .navigationDestination(for: BookSummary.self) { BookView(summary: $0) }
    }
}

// MARK: - Small shared views

@MainActor

struct RoleBadge: View {
    let role: MemberRole

    var body: some View {
        Text(role == .owner ? "Owner" : "Member")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(role == .owner ? RecipeBookTheme.accent : .secondary)
            .background(Capsule().strokeBorder(role == .owner ? RecipeBookTheme.accent : .secondary, lineWidth: 1))
    }
}

@MainActor

struct MetaLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

/// Amount text that never invents a value: unknown amounts read "Amount not specified".
@MainActor
struct AmountText: View {
    let quantity: String?
    let unit: String?

    var body: some View {
        if let text = QuantityText.display(quantity: quantity, unit: unit) {
            Text(text).monospacedDigit()
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Amount not specified")
        }
    }
}

@MainActor

struct AccountIDView: View {
    let accountID: UserID
    @State private var copied = false

    var body: some View {
        HStack {
            Text(accountID)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("Account ID \(accountID)")
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = accountID
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

func formattedMinutes(_ minutes: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
}
#endif
