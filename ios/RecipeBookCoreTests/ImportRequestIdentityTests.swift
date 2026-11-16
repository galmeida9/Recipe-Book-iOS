import XCTest
@testable import RecipeBookCore

final class ImportRequestIdentityTests: XCTestCase {
    func testCanonicalSourceAccountAndBookBindOneStableRetryKeyAcrossAppAndExtension() throws {
        let account = UUID(), book = UUID()
        let source = URL(string: "https://instagram.com/reel/Example/?tracking=ignored")!
        let first = try ImportRequestIdentity.key(accountID: account, bookID: book, sourceURL: source)
        XCTAssertEqual(first, try ImportRequestIdentity.key(accountID: account, bookID: book,
            sourceURL: URL(string: "https://www.instagram.com/reel/Example/")!))
        XCTAssertNotEqual(first, try ImportRequestIdentity.key(accountID: UUID(), bookID: book, sourceURL: source))
        XCTAssertNotEqual(first, try ImportRequestIdentity.key(accountID: account, bookID: UUID(), sourceURL: source))
        XCTAssertThrowsError(try ImportRequestIdentity.key(accountID: account, bookID: book,
            sourceURL: URL(string: "http://127.0.0.1/")!))
    }
}
