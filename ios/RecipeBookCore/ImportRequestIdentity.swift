import Foundation
import CryptoKit

public enum ImportRequestIdentity {
    public static func key(accountID: UUID, bookID: UUID, sourceURL: URL) throws -> UUID {
        guard let source = ReelURL.canonicalize(sourceURL) else {
            throw APIError(status: 0, code: "invalid_reel", message: "Choose an HTTPS Instagram Reel link.")
        }
        let value = "\(accountID.uuidString.lowercased())/\(bookID.uuidString.lowercased())/\(source.absoluteString)"
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
