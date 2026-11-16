import XCTest
@testable import RecipeBookCore
#if canImport(Darwin)
import Darwin
#endif

final class NonblockingFileLockTests: XCTestCase {
    func testContentionFailsImmediatelyAndThrownOperationsReleaseTheLock() throws {
        #if canImport(Darwin)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let start = Date()
        XCTAssertThrowsError(try NonblockingFileLock.withExclusiveAccess(to: url) { XCTFail("Must not enter a held lock.") }) { error in
            XCTAssertEqual((error as? APIError)?.code, "secure_store_busy")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertThrowsError(try NonblockingFileLock.withExclusiveAccess(to: url) { throw CancellationError() })
        XCTAssertEqual(try NonblockingFileLock.withExclusiveAccess(to: url) { 42 }, 42)
        #endif
    }
}
