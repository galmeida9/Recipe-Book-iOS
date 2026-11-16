import XCTest
@testable import RecipeBookCore

final class GoogleTokenNetworkPolicyTests: XCTestCase {
    func testMainAppTokenExchangeAllowsBoundedServerlessResumeWithoutExtendingShareWork() {
        let main = GoogleTokenNetworkPolicy.configuration(isExtension: false)
        XCTAssertEqual(main.timeoutIntervalForRequest, 90)
        XCTAssertEqual(main.timeoutIntervalForResource, 120)
        let share = GoogleTokenNetworkPolicy.configuration(isExtension: true)
        XCTAssertEqual(share.timeoutIntervalForRequest, 20)
        XCTAssertEqual(share.timeoutIntervalForResource, 25)
        XCTAssertFalse(main.waitsForConnectivity)
        XCTAssertFalse(share.waitsForConnectivity)
    }
    func testWrappedAppAuthNetworkFailureKeepsSafeConcreteCodeButNeverRequestSecrets() throws {
        let underlying = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "secret-code-and-token", NSURLErrorFailingURLStringErrorKey: "https://private.invalid/?code=secret"])
        let wrapped = NSError(domain: "org.openid.appauth.general", code: -5, userInfo: [NSUnderlyingErrorKey: underlying])
        let result = try XCTUnwrap(GoogleTokenNetworkPolicy.mapped(wrapped) as? APIError)
        XCTAssertEqual(result.code, "auth_transport_-1001")
        XCTAssertTrue(result.message.contains("No sign-in code was automatically retried"))
        XCTAssertFalse(result.message.contains("secret"))
        XCTAssertFalse(result.message.contains("private.invalid"))
    }
    func testCancellationAndNonTransportErrorsStayDistinct() {
        let wrapped = NSError(domain: "org.openid.appauth.general", code: -5,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)])
        XCTAssertTrue(GoogleTokenNetworkPolicy.mapped(wrapped) is CancellationError)
        let storage = APIError(status: 0, code: "shared_sign_in", message: "Secure shared storage unavailable.")
        XCTAssertEqual((GoogleTokenNetworkPolicy.mapped(storage) as? APIError)?.code, storage.code)
    }
}
