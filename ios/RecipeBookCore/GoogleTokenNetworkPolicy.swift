import Foundation

public enum GoogleTokenNetworkPolicy {
    public static func configuration(isExtension: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Token exchange is asynchronous. A paused serverless database can take
        // longer than ordinary CRUD; a share extension still needs a short bound.
        configuration.timeoutIntervalForRequest = isExtension ? 20 : 90
        configuration.timeoutIntervalForResource = isExtension ? 25 : 120
        configuration.waitsForConnectivity = false
        return configuration
    }

    public static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        var current = error as NSError
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<8 {
            guard visited.insert(ObjectIdentifier(current)).inserted else { break }
            if current.domain == NSURLErrorDomain {
                if current.code == URLError.cancelled.rawValue { return CancellationError() }
                let message: String
                switch current.code {
                case URLError.timedOut.rawValue:
                    message = "Sign-in timed out while contacting Recipe Book. No sign-in code was automatically retried. Start a new sign-in request."
                case URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue,
                     URLError.cannotConnectToHost.rawValue, URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
                    message = "Recipe Book could not complete its secure sign-in connection. Start a new sign-in request when the connection is available."
                case URLError.secureConnectionFailed.rawValue, URLError.serverCertificateUntrusted.rawValue,
                     URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue:
                    message = "iOS could not verify Recipe Book's secure sign-in connection. Certificate verification was not bypassed."
                default:
                    message = "Recipe Book's sign-in connection failed. Start a new sign-in request."
                }
                return APIError(status: 0, code: "auth_transport_\(current.code)", message: "\(message) (Network \(current.code))")
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return error
    }
}
