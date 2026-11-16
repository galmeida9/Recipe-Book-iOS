import SwiftUI
import RecipeBookCore
import RecipeBookPresentation
import RecipeBookUI
import RecipeBookAuth

@main
struct RecipeBookApp: App {
    private let service: Result<any RecipeBookPresentation.RecipeBookService, Error>
    private let installationCheck: Bool
    @State private var incomingReel: URL?
    @State private var inboxError: String?
    @State private var sharedInboxUnavailable = false
    @State private var sharingNotice: String?

    init() {
        #if DEBUG
        installationCheck = Bundle.main.object(forInfoDictionaryKey: "RecipeBookInstallationCheck") as? String == "YES"
            || ProcessInfo.processInfo.arguments.contains("-RecipeBookInstallationCheck")
        if installationCheck {
            let bundleID = Bundle.main.bundleIdentifier ?? "Unavailable"
            let group: String
            do { group = try SharedAppGroup.current() }
            catch { group = "Not authorized: " + error.localizedDescription }
            service = .failure(APIError(status: 0, code: "installation_check",
                message: "Signed bundle ID: \(bundleID)\n\nShared group: \(group)\n\nInstallation check only. No Google login, live recipes, shopping or imports. Keep the share extension when SideStore re-signs the app."))
            return
        }
        #else
        installationCheck = false
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if FixtureShowcaseScreen.fromLaunchArguments() != nil {
            service = .failure(APIError(status: 0, code: "fixture_preview", message: "Fixture previews do not initialize a live service."))
            return
        }
        #endif
        service = Result { try AppConfiguration.service() }
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if let screen = FixtureShowcaseScreen.fromLaunchArguments() {
                FixtureShowcaseView(screen: screen)
            } else {
                applicationContent
            }
            #else
            applicationContent
            #endif
        }
    }
    private var applicationContent: some View {
        Group {
            switch service {
            case .success(let service):
                RecipeBookRootView(service: service, incomingReel: $incomingReel)
            case .failure(let error):
                ContentUnavailableView(installationCheck ? "Installation check only" : "Service setup required",
                                       systemImage: installationCheck ? "iphone" : "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
                    .textSelection(.enabled)
            }
        }
        .onOpenURL { url in
            switch IncomingAppURL.route(url) {
            case .oauth: _ = GoogleAuth.handle(url)
            case .reel(let reel): incomingReel = reel
            case .importInbox:
                if AppConfiguration.importsEnabled { loadInbox() }
                else { inboxError = "Reel importing is not enabled for this core trial. Saved shared links remain queued until imports are available." }
            case .ignored: break
            }
            .onReceive(NotificationCenter.default.publisher(for: GoogleAuth.sharingUnavailableNotification)) { notification in
                sharingNotice = notification.userInfo?["message"] as? String
            }
            .alert("Instagram sharing needs attention", isPresented: Binding(get: { sharingNotice != nil }, set: { if !$0 { sharingNotice = nil } })) {
                Button("OK") { sharingNotice = nil }
            } message: { Text(sharingNotice ?? "") }
        }
        .alert("Unable to read shared Reel", isPresented: Binding(get: { inboxError != nil }, set: { if !$0 { inboxError = nil } })) {
            Button("OK") { inboxError = nil }
        } message: { Text(inboxError ?? "") }
    }
    private func loadInbox() {
        guard incomingReel == nil, !sharedInboxUnavailable else { return }
        do { incomingReel = try SharedReelInbox(appGroup: AppConfiguration.appGroup()).pending().first?.url }
        catch {
            if let failure = error as? APIError, failure.code == "app_group_unavailable" { sharedInboxUnavailable = true }
            inboxError = error.localizedDescription
        }
    }
}
