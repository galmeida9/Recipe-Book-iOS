#if os(iOS) && DEBUG && targetEnvironment(simulator)
import SwiftUI
import RecipeBookPresentation

/// DEBUG Simulator-only showcase of the real screens, backed by the in-memory preview fixtures.
/// It exists so the implemented UI can be screenshotted without a backend. It is compiled out of
/// release and device builds. Google sign-in, Reel import, retry and import approval fail with an
/// explicit fixture message instead of pretending to succeed.
///
/// The bootstrap selects it only when launched with `-RecipeBookFixtureShowcase <screen>`, e.g.
/// `-RecipeBookFixtureShowcase library`. It is never a fallback for missing configuration.
public enum FixtureShowcaseScreen: String, CaseIterable, Sendable {
    case signIn = "sign-in"
    case library
    case recipeDetail = "recipe-detail"
    case shopping
    case plan
    public static let launchArgument = "-RecipeBookFixtureShowcase"

    /// The screen named after `launchArgument`, or nil when the flag is absent or unknown.
    public static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else {
            return nil
        }
        return Self(rawValue: arguments[index + 1])
    }
}

@MainActor
public struct FixtureShowcaseView: View {
    public static let disclosure = "Fixture preview — no live backend or Google sign-in"

    let screen: FixtureShowcaseScreen
    @State private var service: PreviewRecipeBookService

    public init(screen: FixtureShowcaseScreen) {
        self.screen = screen
        _service = State(initialValue: PreviewRecipeBookService(
            session: screen == .signIn ? .signedOut : nil,
            blocksExternalActions: true))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(Self.disclosure)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.black)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemYellow))
                .accessibilityAddTraits(.isStaticText)
            content
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .signIn, .library:
            RecipeBookRootView(service: service)
        case .recipeDetail:
            NavigationStack {
                RecipeDetailView(route: RecipeRoute(id: "r1", title: "Roasted Tomato Soup"))
                    .recipeDestinations()
            }
            .environment(\.recipeBookService, service)
            .tint(RecipeBookTheme.accent)
        case .shopping:
            NavigationStack {
                ShoppingListView(listID: "l1", title: "Weekend")
            }
            .environment(\.recipeBookService, service)
            .tint(RecipeBookTheme.accent)
        case .plan:
            PlanView()
                .environment(\.recipeBookService, service)
                .tint(RecipeBookTheme.accent)
        }
    }
}
#endif
