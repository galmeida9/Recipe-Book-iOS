import Foundation
import Testing
@testable import RecipeBookCore

@Test func sharedGroupResolutionIsUnambiguousAndTeamBound() throws {
    let base = "group.com.recipebook.shared"
    let team = "ABC123DEF4"
    #expect(try SharedAppGroup.resolve(configured: base, identifiers: [base], teamID: nil) == base)
    #expect(try SharedAppGroup.resolve(configured: base, identifiers: [base + "." + team], teamID: team) == base + "." + team)
    #expect(throws: APIError.self) { try SharedAppGroup.resolve(configured: base, identifiers: [], teamID: team) }
    #expect(throws: APIError.self) { try SharedAppGroup.resolve(configured: base, identifiers: [base, base + "." + team], teamID: team) }
    #expect(throws: APIError.self) { try SharedAppGroup.resolve(configured: base, identifiers: [base + "." + team], teamID: nil) }
    #expect(throws: APIError.self) { try SharedAppGroup.resolve(configured: base, identifiers: [base + ".ZZZ123ZZZ9"], teamID: team) }
}

@Test func readsBoundedSignedGroupMetadataAndRejectsMalformedImages() throws {
    let base = "group.com.recipebook.shared"
    let team = "ABC123DEF4"
    let xml = try PropertyListSerialization.data(fromPropertyList: [
        "com.apple.security.application-groups": [base + "." + team],
        "com.apple.developer.team-identifier": team
    ], format: .xml, options: 0)
    func word(_ value: UInt32, bigEndian: Bool = false) -> Data {
        var encoded = bigEndian ? value.bigEndian : value.littleEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
    let signatureLength = UInt32(28 + xml.count)
    var image = Data()
    let header: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0, 0x1d, 16, 48, signatureLength]
    let signature: [UInt32] = [0xfade0cc0, signatureLength, 1, 5, 20, 0xfade7171, UInt32(8 + xml.count)]
    for value in header { image += word(value) }
    for value in signature { image += word(value, bigEndian: true) }
    image += xml
    let metadata = try SharedAppGroup.signedMetadata(in: image)
    #expect(metadata.teamID == team)
    #expect(metadata.identifiers == [base + "." + team])
    #expect(throws: APIError.self) { try SharedAppGroup.signedMetadata(in: Data()) }
    #expect(throws: APIError.self) { try SharedAppGroup.signedMetadata(in: image.prefix(40)) }
    var wrongMagic = image
    wrongMagic[48] = 0
    #expect(throws: APIError.self) { try SharedAppGroup.signedMetadata(in: wrongMagic) }
}
