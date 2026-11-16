#if os(iOS)
import SwiftUI
import RecipeBookPresentation

/// App entry view. Owns access state (signed out / awaiting invite / setup / signed in / guest) and the
/// main tabs. `incomingReel` is set by the app layer when a Reel link is shared into the app; the
/// view clears it once the user has submitted or dismissed the import.
@MainActor
public struct RecipeBookRootView: View {
    private let service: any RecipeBookService
    @Binding private var incomingReel: URL?
    @State private var session: LoadState<SessionState> = .loading
    @State private var reload = 0

    public init(service: any RecipeBookService, incomingReel: Binding<URL?> = .constant(nil)) {
        self.service = service
        self._incomingReel = incomingReel
    }

    public var body: some View {
        Group {
            LoadingContent(state: session, retry: { reload += 1 }) { state in
                switch state {
                case .signedOut:
                    SignInView(onChange: apply)
                case .awaitingInvite(let accountID):
                    AwaitingAccessView(accountID: accountID, onChange: apply)
                case .needsSetup(let profile):
                    ProfileSetupView(profile: profile, onChange: apply)
                case .signedIn(let profile):
                    MainTabView(profile: profile, incomingReel: $incomingReel, onChange: apply)
                case .guest:
                    MainTabView(profile: nil, incomingReel: $incomingReel, onChange: apply)
                }
            }
        }
        .environment(\.recipeBookService, service)
        .tint(RecipeBookTheme.accent)
        .task(id: reload) {
            do {
                session = .loaded(try await service.loadSession())
            } catch let error where !error.isCancellation {
                session = .failed(error.localizedDescription)
            } catch {}
        }
    }

    private func apply(_ state: SessionState) {
        session = .loaded(state)
    }
}

// MARK: - Access states

@MainActor
struct SignInView: View {
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service
    @State private var runner = ActionRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "book.pages")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(RecipeBookTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recipe Book").displayTitle()
                    Text("Keep the recipes you actually cook, and share books with the people you cook with.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(systemImage: "books.vertical", title: "Personal and shared books",
                               detail: "Everyone in a shared book can view and add recipes.")
                    FeatureRow(systemImage: "film", title: "Import from Reels",
                               detail: "Share a public Instagram Reel and review the recipe before saving.")
                    FeatureRow(systemImage: "checklist", title: "Shopping lists",
                               detail: "Tick what you already have; add only what you need.")
                }
                Text("Sign in with your Google account. Recipe Book is invite-only: after signing in, the app administrator needs to grant your account access. Joining a shared book is a separate step done by its owners.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Or continue without signing in to keep personal recipes and shopping lists on this iPhone. You’ll be asked to sign in before sharing books or importing Reels.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .bottomControlBar {
            VStack(spacing: 12) {
                GoogleSignInButton(isRunning: runner.isRunning) {
                    runner.run { onChange(try await service.signIn()) }
                }
                ContinueOnDeviceButton(title: "Continue Without Signing In", runner: runner, onChange: onChange)
                    .font(.body.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
        .errorAlert($runner.errorMessage)
    }
}

@MainActor
private struct FeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(RecipeBookTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct AwaitingAccessView: View {
    let accountID: UserID
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ContentUnavailableView {
                        Label("Waiting for access", systemImage: "envelope.badge")
                    } description: {
                        Text("You’re signed in, but your account hasn’t been granted access to Recipe Book yet. Send your account ID to the app administrator. Being added to a shared book doesn’t grant app access.")
                    }
                }
                Section("Your account ID") {
                    AccountIDView(accountID: accountID)
                    ShareLink(item: accountID, subject: Text("My Recipe Book account ID")) {
                        Label("Share Account ID", systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Button {
                        runner.run { onChange(try await service.loadSession()) }
                    } label: {
                        HStack {
                            Text("Check Again")
                            if runner.isRunning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(runner.isRunning)
                    Button("Sign Out", role: .destructive) {
                        runner.run { try await service.signOut(); onChange(.signedOut) }
                    }
                    .disabled(runner.isRunning)
                }
                Section {
                    ContinueOnDeviceButton(title: "Continue on This iPhone", runner: runner, onChange: onChange)
                } footer: {
                    Text("Use personal books, recipes and shopping lists on this device while you wait. Nothing is uploaded.")
                }
            }
            .navigationTitle("Recipe Book")
        }
        .errorAlert($runner.errorMessage)
    }
}

@MainActor
struct ProfileSetupView: View {
    let profile: UserProfile
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service
    @State private var name: String
    @State private var runner = ActionRunner()

    init(profile: UserProfile, onChange: @escaping (SessionState) -> Void) {
        self.profile = profile
        self.onChange = onChange
        _name = State(initialValue: profile.displayName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.done)
                } header: {
                    Text("What should others see?")
                } footer: {
                    Text("Shown to members of books you share. You can change it later.")
                }
                Section {
                    ContinueOnDeviceButton(title: "Continue on This iPhone Instead", runner: runner, onChange: onChange)
                } footer: {
                    Text("Use personal books, recipes and shopping lists on this device without finishing setup.")
                }
            }
            .navigationTitle("Welcome")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Continue") {
                            let value = trimmed
                            runner.run { onChange(try await service.completeSetup(displayName: value)) }
                        }
                        .disabled(trimmed.isEmpty)
                    }
                }
            }
        }
        .errorAlert($runner.errorMessage)
    }
}

// MARK: - Tabs

@MainActor
struct MainTabView: View {
    enum AppTab: Hashable { case library, plan, shopping, account }

    /// `nil` when the user continued without signing in (on-device guest).
    let profile: UserProfile?
    @Binding var incomingReel: URL?
    let onChange: (SessionState) -> Void
    @State private var tab: AppTab = .library
    @State private var signInFeature: SignInFeature?
    @State private var importsChanged = 0

    var body: some View {
        tabs
            .minimizingTabBarOnScroll()
            .environment(\.accessMode, profile == nil ? .guest : .account)
            .environment(\.requestSignIn, SignInRequest { signInFeature = $0 })
            .sheet(item: $signInFeature) { feature in
                SignInPromptSheet(feature: feature, onChange: onChange)
            }
            .sheet(isPresented: Binding(get: { incomingReel != nil }, set: { if !$0 { incomingReel = nil } })) {
                if let url = incomingReel {
                    if profile == nil {
                        // Keep the shared link: after sign-in the account tabs offer it for import.
                        GuestReelSheet(onChange: onChange) { incomingReel = nil }
                    } else {
                        // Same destination picker as the Share Extension: choose a book, queue, close.
                        ReelImportFlowView(start: .link(url), onSubmitted: { _ in importsChanged += 1 },
                                           onClose: { incomingReel = nil })
                    }
                }
            }
    }

    @ViewBuilder
    private var accountTab: some View {
        if let profile {
            AccountView(profile: profile, onChange: onChange)
        } else {
            GuestAccountView(onChange: onChange)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18, *) {
            TabView(selection: $tab) {
                Tab("Library", systemImage: "books.vertical", value: AppTab.library) { LibraryView(importsChanged: importsChanged) }
                Tab("Plan", systemImage: "calendar", value: AppTab.plan) { PlanView() }
                Tab("Shopping", systemImage: "cart", value: AppTab.shopping) { ShoppingListsView() }
                Tab("Account", systemImage: "person.crop.circle", value: AppTab.account) { accountTab }
            }
        } else {
            TabView(selection: $tab) {
                LibraryView(importsChanged: importsChanged)
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(AppTab.library)
                PlanView()
                    .tabItem { Label("Plan", systemImage: "calendar") }
                    .tag(AppTab.plan)
                ShoppingListsView()
                    .tabItem { Label("Shopping", systemImage: "cart") }
                    .tag(AppTab.shopping)
                accountTab
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(AppTab.account)
            }
        }
    }
}

// MARK: - Guest surfaces

/// Shown when a Reel is shared into the app while the user isn't signed in. Signing in keeps the
/// link so the account tabs can offer it for import; "Not Now" dismisses it.
@MainActor
private struct GuestReelSheet: View {
    let onChange: (SessionState) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            SignInPromptView(feature: .importing, onChange: onChange)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not Now", action: onDismiss)
                    }
                }
        }
    }
}

/// Account tab for guests: states where data lives and offers Google sign-in.
@MainActor
private struct GuestAccountView: View {
    let onChange: (SessionState) -> Void
    @Environment(\.recipeBookService) private var service
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            SignInPromptView(feature: .account, onChange: onChange)
                .navigationTitle("Account")
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Back to Sign-In Screen") {
                            runner.run { try await service.signOut(); onChange(.signedOut) }
                        }
                        .disabled(runner.isRunning)
                    }
                }
        }
        .errorAlert($runner.errorMessage)
    }
}
#endif
