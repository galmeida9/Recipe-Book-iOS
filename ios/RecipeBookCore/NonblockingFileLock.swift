import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum NonblockingFileLock {
    public static func withExclusiveAccess<T>(to url: URL, _ operation: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw APIError(status: 0, code: "secure_store_lock", message: "Secure sign-in storage could not be opened.")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw APIError(status: 409, code: "secure_store_busy", message: "Sign-in storage is busy in another app window. Close the other sheet and try again.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
        #else
        throw APIError(status: 0, code: "secure_store_lock", message: "Shared secure sign-in requires the supported native Apple runtime.")
        #endif
    }
}
