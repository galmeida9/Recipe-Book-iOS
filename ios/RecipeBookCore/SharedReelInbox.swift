import Foundation

public struct SharedReelInbox: Sendable {
    public let appGroup: String
    public init(appGroup: String) { self.appGroup = appGroup }

    public func enqueue(_ url: URL) throws {
        guard let canonical = ReelURL.canonicalize(url) else {
            throw APIError(status: 0, code: "invalid_reel", message: "Only public Instagram Reel URLs are supported.")
        }
        let directory = try container()
        try Data(canonical.absoluteString.utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".reel"), options: .atomic)
    }

    public func pending() throws -> [(id: String, url: URL)] {
        let directory = try container()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "reel" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                let text = try String(contentsOf: file, encoding: .utf8)
                guard let url = URL(string: text), let canonical = ReelURL.canonicalize(url) else {
                    throw APIError(status: 0, code: "invalid_inbox", message: "The shared URL could not be read.")
                }
                return (file.deletingPathExtension().lastPathComponent, canonical)
            }
    }

    public func acknowledge(id: String) throws {
        guard UUID(uuidString: id) != nil else {
            throw APIError(status: 0, code: "invalid_inbox_id", message: "Invalid shared import identifier.")
        }
        try FileManager.default.removeItem(at: container().appendingPathComponent(id + ".reel"))
    }

    private func container() throws -> URL {
        #if os(iOS)
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw APIError(status: 0, code: "app_group_unavailable", message: "The shared app group is not provisioned.")
        }
        let directory = root.appendingPathComponent("ReelInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
        #else
        throw APIError(status: 0, code: "unsupported_platform", message: "The share inbox requires iOS app-group entitlements.")
        #endif
    }
}
