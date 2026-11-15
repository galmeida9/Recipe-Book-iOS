#if os(iOS)
import SwiftUI
import RecipeBookPresentation

/// App entry view. Owns access state (signed out / awaiting invite / setup / signed in) and the
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
                Text("Recipe Book is invite-only. After signing in, the app administrator needs to grant your account access. Joining a shared book is a separate step done by its owners.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            RunningButton(title: "Sign In", isRunning: runner.isRunning) {
                runner.run { onChange(try await service.signIn()) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .background(.bar)
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
    enum Tab: Hashable { case library, suggestions, imports, shopping, account }

    let profile: UserProfile
    @Binding var incomingReel: URL?
    let onChange: (SessionState) -> Void
    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(Tab.library)
            SuggestionsView()
                .tabItem { Label("Cook", systemImage: "frying.pan") }
                .tag(Tab.suggestions)
            ImportsView()
                .tabItem { Label("Imports", systemImage: "square.and.arrow.down") }
                .tag(Tab.imports)
            ShoppingListsView()
                .tabItem { Label("Shopping", systemImage: "cart") }
                .tag(Tab.shopping)
            AccountView(profile: profile, onChange: onChange)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(Tab.account)
        }
        .sheet(isPresented: Binding(get: { incomingReel != nil }, set: { if !$0 { incomingReel = nil } })) {
            if let url = incomingReel {
                ReelImportConfirmView(url: url) { job in
                    incomingReel = nil
                    if job != nil { tab = .imports }
                }
            }
        }
    }
}
#endif
