import Foundation

public enum IncomingAppURL: Equatable, Sendable {
    case oauth
    case reel(URL)
    case importInbox
    case ignored

    public static func route(_ url: URL) -> Self {
        if url.scheme == "recipebook", url.host == "oauth", url.path.isEmpty { return .oauth }
        if let reel = ReelURL.canonicalize(url) { return .reel(reel) }
        if url.scheme == "recipebook", url.host == "import", url.path.isEmpty { return .importInbox }
        return .ignored
    }
}
