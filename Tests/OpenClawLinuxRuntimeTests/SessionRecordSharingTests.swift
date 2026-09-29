import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol

/// Session-sharing fields on ``SessionRecord`` (owner, participants, members, visibility,
/// per-profile involvement).
@Suite("Session record sharing fields")
struct SessionRecordSharingTests {
    @Test
    func sharingFieldsRoundTripAndOldRecordsStillDecode() throws {
        let legacy = Data(#"{"key":"agent:main:main","agentID":"main","updatedAtMs":5}"#.utf8)
        let old = try JSONDecoder().decode(SessionRecord.self, from: legacy)
        #expect(old.owner == nil)
        #expect(old.createdActor == nil)
        #expect(old.participants == nil)
        #expect(old.profileInvolvement == nil)
        #expect(old.visibility == nil)
        #expect(old.members == nil)
        #expect(old.participantCount == nil)

        var record = old
        record.createdActor = ["type": AnyCodable("human"), "id": AnyCodable("p1"), "source": AnyCodable("profile")]
        record.owner = ["actor": AnyCodable(["type": AnyCodable("human"), "id": AnyCodable("p2")]), "assignedAt": AnyCodable(Int64(1_789_948_800_000))]
        record.participants = [["identity": AnyCodable(["type": AnyCodable("human"), "id": AnyCodable("p2")])]]
        record.profileInvolvement = ["p1": SessionProfileInvolvement(hidden: true, updatedAt: 1_789_948_800_000)]
        record.visibility = .readOnly
        record.members = [SessionMember(identityID: "p3", addedBy: "p2", addedAt: 1_789_948_800_001), SessionMember(identityID: "p4", addedAt: 7)]
        record.participantCount = 3
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        #expect(encoded?["visibility"] as? String == "read-only")
        #expect((encoded?["members"] as? [[String: Any]])?.first?["identityId"] as? String == "p3")
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)

        let malformed = Data(#"{"key":"k","agentID":"main","updatedAtMs":5,"owner":"nobody","profileInvolvement":{"p":{"hidden":true}}}"#.utf8)
        let tolerant = try JSONDecoder().decode(SessionRecord.self, from: malformed)
        #expect(tolerant.owner == nil)
        #expect(tolerant.profileInvolvement?["p"] == SessionProfileInvolvement(hidden: true, updatedAt: 0))

        // Unknown visibility values decode as nil; malformed members are skipped, not fatal.
        let members = #"[{"identityId":"a","addedAt":1.0},{"addedBy":"x"},"junk",{"identityId":"b"}]"#
        let mixed = Data(#"{"key":"k","agentID":"main","updatedAtMs":5,"visibility":"Private","participantCount":2,"members":\#(members)}"#.utf8)
        let lossy = try JSONDecoder().decode(SessionRecord.self, from: mixed)
        #expect(lossy.visibility == nil)
        #expect(lossy.members == [SessionMember(identityID: "a", addedAt: 1), SessionMember(identityID: "b", addedAt: 0)])
        #expect(lossy.participantCount == 2)
        let draft = Data(#"{"key":"k","agentID":"main","updatedAtMs":5,"visibility":" DRAFT "}"#.utf8)
        #expect(try JSONDecoder().decode(SessionRecord.self, from: draft).visibility == .draft)
    }
}
