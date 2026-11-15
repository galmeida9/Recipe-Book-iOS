#if DEBUG
import Foundation
import Testing
@testable import RecipeBookCore

@Test func inboxAcknowledgementIsCaseIndependentAndIdempotent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-inbox-test-" + UUID().uuidString)
    let inbox = SharedReelInbox(testDirectory: directory)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record(error) }
    }
    try inbox.enqueue(URL(string: "https://www.instagram.com/reel/TEST123/?tracking=removed")!)
    let pending = try inbox.pending()
    #expect(pending.count == 1)
    #expect(pending.first?.url.absoluteString == "https://www.instagram.com/reel/TEST123/")
    let id = try #require(pending.first?.id)
    async let first: Void = Task.detached { try inbox.acknowledge(id: id.lowercased()) }.value
    async let second: Void = Task.detached { try inbox.acknowledge(id: id) }.value
    _ = try await (first, second)
    #expect(try inbox.pending().isEmpty)
    try inbox.acknowledge(id: id)
    #expect(throws: APIError.self) { try inbox.acknowledge(id: "../invalid") }
    #expect(throws: APIError.self) { try inbox.enqueue(URL(string: "https://example.com/")!) }
}

@Test func concurrentInboxScansAndAcknowledgementsDoNotLoseNewFilesOrHideCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-inbox-test-" + UUID().uuidString)
    let inbox = SharedReelInbox(testDirectory: directory)
    _ = try inbox.pending()
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record(error) }
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for _ in 0..<100 { _ = try inbox.pending() }
        }
        group.addTask {
            for _ in 0..<100 {
                try inbox.enqueue(URL(string: "https://www.instagram.com/reel/TEST123/")!)
                for entry in try inbox.pending() { try inbox.acknowledge(id: entry.id) }
            }
        }
        try await group.waitForAll()
    }
    try inbox.enqueue(URL(string: "https://www.instagram.com/reel/RETAIN123/")!)
    #expect(try inbox.pending().count == 1)
    try Data("not an Instagram Reel".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".reel"))
    #expect(throws: APIError.self) { try inbox.pending() }
}
#endif
