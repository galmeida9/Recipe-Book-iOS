import SwiftUI
import RecipeBookCore
import RecipeBookPresentation
import RecipeBookUI

@main
struct RecipeBookApp: App {
    private let service: Result<any RecipeBookPresentation.RecipeBookService, Error>
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingReel: URL?
    @State private var inboxError: String?

    init() { service = Result { try AppConfiguration.service() } }
    var body: some Scene {
        WindowGroup {
            Group {
                switch service {
                case .success(let service):
                    RecipeBookRootView(service: service, incomingReel: $incomingReel)
                case .failure(let error):
                    ContentUnavailableView("Service setup required", systemImage: "exclamationmark.triangle",
                                           description: Text(error.localizedDescription))
                }
            }
            .onOpenURL { url in
                if let reel = ReelURL.canonicalize(url) { incomingReel = reel }
                else if url.scheme == "recipebook", url.host == "import" { loadInbox() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { loadInbox() }
            }
            .task { loadInbox() }
            .alert("Unable to read shared Reel", isPresented: Binding(get: { inboxError != nil }, set: { if !$0 { inboxError = nil } })) {
                Button("OK") { inboxError = nil }
            } message: { Text(inboxError ?? "") }
        }
    }
    private func loadInbox() {
        guard incomingReel == nil else { return }
        do { incomingReel = try SharedReelInbox(appGroup: AppConfiguration.appGroup()).pending().first?.url }
        catch { inboxError = error.localizedDescription }
    }
}
