import Foundation

public struct SharedReelInbox: Sendable {
    public let appGroup: String
    #if DEBUG
    private let testDirectory: URL?
    init(testDirectory: URL) {
        appGroup = "test-only"
        self.testDirectory = testDirectory
    }
    #endif
    public init(appGroup: String) {
        self.appGroup = appGroup
        #if DEBUG
        testDirectory = nil
        #endif
    }

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
            .compactMap { file -> (id: String, url: URL)? in
                let text: String
                do { text = try String(contentsOf: file, encoding: .utf8) }
                catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    // Another committed submission may have acknowledged this file.
                    return nil
                }
                guard let url = URL(string: text), let canonical = ReelURL.canonicalize(url) else {
                    throw APIError(status: 0, code: "invalid_inbox", message: "The shared URL could not be read.")
                }
                return (file.deletingPathExtension().lastPathComponent, canonical)
            }
    }

    public func acknowledge(id: String) throws {
        guard let identifier = UUID(uuidString: id) else {
            throw APIError(status: 0, code: "invalid_inbox_id", message: "Invalid shared import identifier.")
        }
        let file = try container().appendingPathComponent(identifier.uuidString + ".reel")
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Acknowledgement is idempotent after a committed server job.
            return
        }
    }

    private func container() throws -> URL {
        #if DEBUG
        if let testDirectory {
            try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
            return testDirectory
        }
        #endif
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
