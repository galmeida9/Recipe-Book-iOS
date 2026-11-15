import Foundation

public enum ReelURL {
    public static func canonicalize(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["instagram.com", "www.instagram.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "reel",
              !parts[1].isEmpty,
              parts[1].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }) else { return nil }
        return URL(string: "https://www.instagram.com/reel/\(parts[1])/")
    }
}
