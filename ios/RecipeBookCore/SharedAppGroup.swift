import Foundation

public enum SharedAppGroup {
    public static func current(bundle: Bundle = .main) throws -> String {
        guard let configured = bundle.object(forInfoDictionaryKey: "RecipeBookAppGroup") as? String,
              let executable = bundle.executableURL else { throw failure("The shared group and app executable must be configured.") }
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        let metadata = try signedMetadata(in: data)
        let identifier = try resolve(configured: configured, identifiers: metadata.identifiers, teamID: metadata.teamID)
        #if os(iOS)
        // Metadata does not grant access: iOS must authorize the actual container.
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil else {
            throw failure("iOS denied the shared group. Re-sign both Recipe Book and its share extension with matching authorized profiles; keep the extension.")
        }
        return identifier
        #else
        throw failure("Shared-group access requires an authorized signed iOS build.")
        #endif
    }

    static func resolve(configured: String, identifiers: [String], teamID: String?) throws -> String {
        guard configured.hasPrefix("group."), !configured.contains("$("), configured.count > 6 else {
            throw failure("RecipeBookAppGroup must name the original shared group.")
        }
        let validTeam = teamID.flatMap { value in
            value.count == 10 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) } ? value : nil
        }
        let matches = Set(identifiers.filter { identifier in
            if identifier == configured { return true }
            guard let validTeam else { return false }
            return identifier == configured + "." + validTeam
        })
        guard matches.count == 1, let identifier = matches.first else {
            throw failure(matches.isEmpty
                ? "The signed profile has no matching shared group. Re-sign both targets together and keep the share extension."
                : "The signed profile contains ambiguous shared groups. Re-sign both targets with one matching shared group.")
        }
        return identifier
    }

    struct Metadata: Sendable { let identifiers: [String]; let teamID: String? }

    static func signedMetadata(in data: Data) throws -> Metadata {
        guard data.count <= 100 * 1024 * 1024 else { throw failure("The executable exceeds the supported metadata-reading limit.") }
        func word(_ offset: Int, bigEndian: Bool = false) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw failure("Signed metadata is truncated. Re-sign the complete app and extension.") }
            let index = data.startIndex + offset
            let value = data[index..<(index + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Int(bigEndian ? value : value.byteSwapped)
        }
        // Only the thin 64-bit format built by our iOS target is supported.
        guard try word(0) == 0xfeedfacf else { throw failure("Unsupported executable format. Build and re-sign the thin 64-bit iOS targets.") }
        let count = try word(16)
        let commandEnd = 32 + (try word(20))
        guard count <= 4096, commandEnd <= data.count else { throw failure("Executable load commands are invalid.") }
        var cursor = 32
        var signature: (offset: Int, size: Int)?
        for _ in 0..<count {
            let command = try word(cursor)
            let size = try word(cursor + 4)
            guard size >= 8, size <= commandEnd - cursor else { throw failure("Executable load commands are truncated.") }
            if command == 0x1d {
                guard size >= 16, signature == nil else { throw failure("The executable has ambiguous code signatures.") }
                signature = (try word(cursor + 8), try word(cursor + 12))
            }
            cursor += size
        }
        guard cursor == commandEnd, let signature, signature.offset >= commandEnd,
              signature.size >= 12, signature.offset <= data.count - signature.size else {
            throw failure("Signed metadata is missing. Re-sign both targets with their authorized profiles.")
        }
        let start = signature.offset
        guard try word(start, bigEndian: true) == 0xfade0cc0 else { throw failure("Unsupported embedded signature metadata.") }
        let length = try word(start + 4, bigEndian: true)
        let entries = try word(start + 8, bigEndian: true)
        guard length >= 12, length <= signature.size, entries <= 128, 12 + entries * 8 <= length else {
            throw failure("Embedded signature metadata is invalid.")
        }
        var xml: Data?
        for index in 0..<entries {
            let slot = start + 12 + index * 8
            guard try word(slot, bigEndian: true) == 5 else { continue }
            let offset = try word(slot + 4, bigEndian: true)
            guard offset >= 12 + entries * 8, offset <= length - 8, xml == nil else {
                throw failure("Signed entitlements are missing or ambiguous.")
            }
            let blob = start + offset
            guard try word(blob, bigEndian: true) == 0xfade7171 else { throw failure("Unsupported signed XML entitlements.") }
            let size = try word(blob + 4, bigEndian: true)
            guard size >= 8, size <= 65_536, size <= length - offset else { throw failure("Signed entitlements are truncated or oversized.") }
            xml = data[(data.startIndex + blob + 8)..<(data.startIndex + blob + size)]
        }
        guard let xml else { throw failure("Signed XML entitlements are unavailable. Check the signer and both profiles before installing.") }
        let plist = try PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
        guard let values = plist as? [String: Any],
              let identifiers = values["com.apple.security.application-groups"] as? [String] else {
            throw failure("The signed targets must include the shared App Group entitlement.")
        }
        return Metadata(identifiers: identifiers, teamID: values["com.apple.developer.team-identifier"] as? String)
    }

    private static func failure(_ message: String) -> APIError {
        APIError(status: 0, code: "app_group_unavailable", message: message)
    }
}
