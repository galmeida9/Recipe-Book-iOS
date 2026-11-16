import Foundation
import XCTest
import RecipeBookCore
import RecipeBookAuth
import RecipeBookPresentation

private actor TestAuthentication: AuthenticationSession {
    private var active = true
    private(set) var signOutCount = 0
    func hasSession() -> Bool { active }
    func signIn() { active = true }
    func signOut() { active = false; signOutCount += 1 }
    func accessToken() -> String { "synthetic-test-token" }
}

private final class HTTPFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 500
    private var data = Data()
    private var requests: [URLRequest] = []
    func reset(_ json: String, status: Int = 200) {
        lock.withLock { self.status = status; data = Data(json.utf8); requests = [] }
    }
    func respond(_ json: String, status: Int = 200) {
        lock.withLock { self.status = status; data = Data(json.utf8) }
    }
    func receive(_ request: URLRequest) -> (Int, Data) {
        lock.withLock { requests.append(request); return (status, data) }
    }
    func recordedRequests() -> [URLRequest] { lock.withLock { requests } }
}

private final class HTTPFixture: URLProtocol, @unchecked Sendable {
    static let state = HTTPFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.state.receive(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AdapterTests: XCTestCase {
    private let accountID = "a0000000-0000-0000-0000-000000000001"

    func testPastedImportBindsDestinationAndAccountWithoutReadingAnAppGroupInbox() async throws {
        let (service, _) = try adapter()
        let bookID = "b0000000-0000-0000-0000-000000000001"
        HTTPFixture.state.reset("""
        {"id":"\(accountID)","displayName":"Fixture","access":"active","state":"queued",
         "sourceURL":"https://www.instagram.com/reel/Fixture/","draft":null,"evidence":null,
         "error":null,"version":1,"createdAt":"2026-11-16T00:00:00.000Z",
         "recipeId":null,"bookId":null,"destinationBookId":"\(bookID)","stage":"queued","isUnseen":false}
        """)
        let url = URL(string: "https://instagram.com/reel/Fixture/?tracking=ignored")!
        let first = try await service.submitImport(url: url, bookID: bookID)
        let second = try await service.submitImport(url: url, bookID: bookID)
        XCTAssertEqual(first.bookID, bookID)
        XCTAssertEqual(first.status, .queued)
        XCTAssertEqual(second.id, first.id)
        let posts = HTTPFixture.state.recordedRequests().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].timeoutInterval, 20)
        XCTAssertEqual(posts[0].value(forHTTPHeaderField: "Idempotency-Key"), posts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(posts[0].value(forHTTPHeaderField: "X-Recipe-Account-ID"), accountID)
        var encoded = posts[0].httpBody
        if encoded == nil, let stream = posts[0].httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            encoded = data
        }
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(encoded)) as? [String: String])
        XCTAssertEqual(body["bookId"]?.lowercased(), bookID)
        XCTAssertEqual(body["sourceURL"], "https://www.instagram.com/reel/Fixture/")
    }

    private func adapter() throws -> (UIServiceAdapter, TestAuthentication) {
        let auth = TestAuthentication()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPFixture.self]
        let api = try APIClient(baseURL: URL(string: "https://fixture.invalid/api")!, tokens: auth, session: URLSession(configuration: configuration))
        return (UIServiceAdapter(api: api, auth: auth, inbox: SharedReelInbox(appGroup: "group.invalid.fixture")), auth)
    }

    func testInviteSetupAndSignedInStatesMatchBackend() async throws {
        let (service, _) = try adapter()
        HTTPFixture.state.reset("""
        {"id":"\(accountID)","displayName":null,"access":"awaitingInvite"}
        """)
        let waiting = try await service.loadSession()
        XCTAssertEqual(waiting, .awaitingInvite(accountID: accountID))
        HTTPFixture.state.respond("""
        {"id":"\(accountID)","displayName":null,"access":"active"}
        """)
        let setup = try await service.loadSession()
        XCTAssertEqual(setup, .needsSetup(UserProfile(id: accountID, displayName: "")))
        HTTPFixture.state.respond("""
        {"id":"\(accountID)","displayName":"Fixture","access":"active"}
        """)
        let signedIn = try await service.loadSession()
        XCTAssertEqual(signedIn, .signedIn(UserProfile(id: accountID, displayName: "Fixture")))
    }

    func testUnauthorizedSignsOutButQuotaFailureDoesNotFabricateSession() async throws {
        let (service, auth) = try adapter()
        HTTPFixture.state.reset(#"{"code":"database_unavailable","message":"Quota paused"}"#, status: 503)
        do { _ = try await service.loadSession(); XCTFail("Quota errors must remain visible.") }
        catch let error as APIError { XCTAssertEqual(error.status, 503) }
        let stillActive = await auth.hasSession()
        XCTAssertTrue(stillActive)
        HTTPFixture.state.respond(#"{"code":"signed_out","message":"Expired"}"#, status: 401)
        let signedOut = try await service.loadSession()
        XCTAssertEqual(signedOut, .signedOut)
        let signOutCount = await auth.signOutCount
        XCTAssertEqual(signOutCount, 1)
    }

    func testImportReviewPreservesEvidenceAndRequiresDestination() async throws {
        let (service, _) = try adapter()
        let id = "b0000000-0000-0000-0000-000000000001"
        HTTPFixture.state.reset("""
        {"id":"\(id)","sourceURL":"https://www.instagram.com/reel/Fixture/","state":"review","version":7,
         "createdAt":"2026-11-15T00:00:00.000Z","error":null,"recipeId":null,"bookId":null,
         "draft":{"title":"Soup","ingredients":[{"name":"carrots","quantity":null,"unit":null,"preparation":null}],
          "steps":["Cook"],"servings":null,"totalMinutes":null,"sourceURL":"https://www.instagram.com/reel/Fixture/"},
         "evidence":{"caption":"Ingredients: carrots","comments":["Missing amount"],"transcript":null}}
        """)
        let review = try await service.importReview(id: id)
        XCTAssertNil(review.bookID)
        XCTAssertNil(review.ingredients[0].quantity)
        XCTAssertTrue(review.evidenceText?.contains("Missing amount") == true)
        do { _ = try await service.approveImport(id: id, draft: review); XCTFail("A book must be chosen explicitly.") }
        catch let error as APIError { XCTAssertEqual(error.code, "client_state") }
        XCTAssertEqual(HTTPFixture.state.recordedRequests().count, 1)
    }

    func testShoppingMutationSendsCachedVersionAndDoesNotRetryStaleWrite() async throws {
        let (service, _) = try adapter()
        let id = "c0000000-0000-0000-0000-000000000001"
        HTTPFixture.state.reset("""
        [{"id":"\(id)","name":"Fixture","items":[],"version":7}]
        """)
        _ = try await service.shoppingLists()
        HTTPFixture.state.respond(#"{"code":"stale_version","message":"Reload"}"#, status: 412)
        do {
            _ = try await service.addShoppingItem(ShoppingItemDraft(name: "carrots", quantity: "1", unit: "g"), to: id)
            XCTFail("Stale writes must remain visible.")
        } catch let error as APIError { XCTAssertEqual(error.status, 412) }
        let requests = HTTPFixture.state.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Match"), "7")
    }
}
