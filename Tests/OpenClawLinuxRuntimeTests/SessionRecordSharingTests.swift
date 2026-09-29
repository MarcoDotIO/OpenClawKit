import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol

/// Session-sharing fields on ``SessionRecord`` (owner, participants, per-profile involvement).
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

        var record = old
        record.createdActor = ["type": AnyCodable("human"), "id": AnyCodable("p1"), "source": AnyCodable("profile")]
        record.owner = ["actor": AnyCodable(["type": AnyCodable("human"), "id": AnyCodable("p2")]), "assignedAt": AnyCodable(Int64(1_789_948_800_000))]
        record.participants = [["identity": AnyCodable(["type": AnyCodable("human"), "id": AnyCodable("p2")])]]
        record.profileInvolvement = ["p1": SessionProfileInvolvement(hidden: true, updatedAt: 1_789_948_800_000)]
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)

        let malformed = Data(#"{"key":"k","agentID":"main","updatedAtMs":5,"owner":"nobody","profileInvolvement":{"p":{"hidden":true}}}"#.utf8)
        let tolerant = try JSONDecoder().decode(SessionRecord.self, from: malformed)
        #expect(tolerant.owner == nil)
        #expect(tolerant.profileInvolvement?["p"] == SessionProfileInvolvement(hidden: true, updatedAt: 0))
    }
}
