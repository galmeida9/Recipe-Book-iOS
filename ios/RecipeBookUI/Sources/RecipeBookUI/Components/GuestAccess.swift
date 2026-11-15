#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// MARK: - Access mode & contextual sign-in

/// Whether the main tabs run with a Recipe Book account or as an on-device guest.
enum AccessMode: Equatable {
    case account
    case guest
}

/// Asks the root to present the contextual Google sign-in prompt for a cloud-only feature.
struct SignInRequest {
    let action: @MainActor (SignInFeature) -> Void

    @MainActor
    func callAsFunction(_ feature: SignInFeature) { action(feature) }
}

private struct AccessModeKey: EnvironmentKey {
    static let defaultValue: AccessMode = .account
}

private struct SignInRequestKey: EnvironmentKey {
    static let defaultValue = SignInRequest { _ in }
}

extension EnvironmentValues {
    var accessMode: AccessMode {
        get { self[AccessModeKey.self] }
        set { self[AccessModeKey.self] = newValue }
    }

    var requestSignIn: SignInRequest {
        get { self[SignInRequestKey.self] }
        set { self[SignInRequestKey.self] = newValue }
    }
}

extension SignInFeature {
    var systemImage: String {
        switch self {
        case .sharing: return "person.2"
        case .importing: return "square.and.arrow.down"
        case .suggestions: return "frying.pan"
        case .account: return "person.crop.circle"
        }
    }
}

/// Explains why a feature needs an account and offers Google sign-in. Signing in never moves or
/// deletes on-device data.
@MainActor
struct SignInPromptView: View {
    let feature: SignInFeature
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service
    @State private var runner = ActionRunner()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(RecipeBookTheme.accent)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(feature.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(feature.message)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                GoogleSignInButton(isRunning: runner.isRunning) {
                    runner.run { onChange(try await service.signIn()) }
                }
                Text("Recipe Book is invite-only. After signing in, the app administrator may need to grant your account access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .errorAlert($runner.errorMessage)
    }
}

/// Sheet form of `SignInPromptView`, presented when a guest taps a cloud-only action.
@MainActor
struct SignInPromptSheet: View {
    let feature: SignInFeature
    let onChange: (SessionState) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInPromptView(feature: feature) { state in
                dismiss()
                onChange(state)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Truthful indicator that the user is not signed in and data lives only on this device.
@MainActor
struct OnDeviceBanner: View {
    @Environment(\.requestSignIn) private var requestSignIn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On this iPhone").font(.subheadline.weight(.semibold))
                    Text("You’re not signed in. Your books, recipes and lists are saved only on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "iphone")
                    .foregroundStyle(RecipeBookTheme.accent)
            }
            Button("Sign In to Share and Import") { requestSignIn(.account) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Explicit consent before uploading a copy of an on-device book. The original stays on the device.
@MainActor
struct CopyToAccountSheet: View {
    let book: BookSummary
    let onCopied: (BookSummary) -> Void
    @Environment(\.recipeBookService) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var kind: BookKind
    @State private var runner = ActionRunner()

    init(book: BookSummary, initialKind: BookKind = .shared, onCopied: @escaping (BookSummary) -> Void) {
        self.book = book
        self.onCopied = onCopied
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("To share “\(book.name)”, Recipe Book needs to upload a copy to your account.")
                }
                Section {
                    Picker("Copy as", selection: $kind) {
                        Text("Shared").tag(BookKind.shared)
                        Text("Personal").tag(BookKind.personal)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind == .shared
                         ? "You’ll be the owner of the new shared book and can add people by account ID."
                         : "The new book is visible only to you in your account.")
                }
                Section("What happens") {
                    Label(book.recipeCount == 1
                          ? "This book and its 1 recipe are copied to your account."
                          : "This book and its \(book.recipeCount) recipes are copied to your account.",
                          systemImage: "icloud.and.arrow.up")
                    Label("The original stays on this iPhone. Nothing else is uploaded.", systemImage: "iphone")
                    Label("Later changes to either copy aren’t synced.", systemImage: "arrow.triangle.branch")
                }
            }
            .navigationTitle("Copy to Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Copy") {
                            let id = book.id, kind = kind
                            runner.run {
                                let copy = try await service.copyLocalBookToAccount(id: id, kind: kind)
                                onCopied(copy)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .errorAlert($runner.errorMessage)
    }
}

/// Secondary "use without an account" action shown on sign-in, awaiting-access and setup screens.
@MainActor
struct ContinueOnDeviceButton: View {
    let title: String
    let runner: ActionRunner
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service

    var body: some View {
        Button(title) {
            runner.run { onChange(try await service.continueWithoutSignIn()) }
        }
        .disabled(runner.isRunning)
        .accessibilityHint("Use Recipe Book without an account. Your data stays on this device.")
    }
}
#endif
