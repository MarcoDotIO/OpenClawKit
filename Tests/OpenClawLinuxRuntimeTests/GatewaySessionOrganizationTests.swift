import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
@testable import OpenClawAgents

/// Session organization over the in-process server: pin/archive/rename/unread/color through
/// `sessions.patch`, `sessions.groups.*`, agent-scoped listing.
@Suite("Gateway session organization", .timeLimit(.minutes(1)))
struct GatewaySessionOrganizationTests {
    private typealias Harness = GatewayServerTestHarness

    @Test
    func patchOrganizesSessionsAndListReflectsIt() async throws {
        let (server, _) = Harness.bareServer("org-patch")
        for key in ["agent:main:a", "agent:main:b", "agent:ops:c"] {
            #expect(await Harness.call(server, "sessions.patch", ["key": AnyCodable(key)]).ok)
        }
        let pinned = try Harness.payload(await Harness.call(server, "sessions.patch", [
            "key": AnyCodable("agent:main:b"), "pinned": AnyCodable(true), "label": AnyCodable("Renamed"),
            "color": AnyCodable("teal"), "unread": AnyCodable(true),
        ]))
        let row = try #require(pinned["session"]?.dictionaryValue)
        #expect(row["pinned"] == AnyCodable(true))
        #expect(row["pinnedAt"]?.int64Value != nil)
        #expect(row["label"] == AnyCodable("Renamed"))
        #expect(row["color"] == AnyCodable("teal"))
        #expect(row["unread"] == AnyCodable(true))
        _ = await Harness.call(server, "sessions.patch", ["key": AnyCodable("agent:main:a"), "archived": AnyCodable(true)])

        let all = try Harness.payload(await Harness.call(server, "sessions.list"))
        let keys = all["sessions"]?.arrayValue?.compactMap { $0.dictionaryValue?["key"]?.stringValue }
        #expect(keys?.first == "agent:main:b")
        #expect(all["totalCount"] == AnyCodable(3))

        let active = try Harness.payload(await Harness.call(server, "sessions.list", ["archived": AnyCodable(false), "agentId": AnyCodable("main")]))
        #expect(active["sessions"]?.arrayValue?.compactMap { $0.dictionaryValue?["key"]?.stringValue } == ["agent:main:b"])
        let archived = try Harness.payload(await Harness.call(server, "sessions.list", ["archived": AnyCodable("only")]))
        #expect(archived["sessions"]?.arrayValue?.compactMap { $0.dictionaryValue?["key"]?.stringValue } == ["agent:main:a"])
        let paged = try Harness.payload(await Harness.call(server, "sessions.list", ["limit": AnyCodable(1), "offset": AnyCodable(1)]))
        #expect(paged["count"] == AnyCodable(1))
        #expect(paged["nextOffset"] == AnyCodable(2))
        let searched = try Harness.payload(await Harness.call(server, "sessions.list", ["search": AnyCodable("renamed")]))
        #expect(searched["count"] == AnyCodable(1))

        // Deleting with archivedOnly requires an archived session.
        let refused = await Harness.call(server, "sessions.delete", ["key": AnyCodable("agent:main:b"), "archivedOnly": AnyCodable(true)])
        #expect(refused.error?.errorCode == .invalidRequest)
        #expect(await Harness.call(server, "sessions.delete", ["key": AnyCodable("agent:main:a"), "archivedOnly": AnyCodable(true)]).ok)
    }

    @Test
    func groupsCatalogKeepsSessionsWhenRenamedOrDeleted() async throws {
        let (server, store) = Harness.bareServer("org-groups")
        let put = try Harness.payload(await Harness.call(server, "sessions.groups.put", [
            "names": AnyCodable([AnyCodable(" Work "), AnyCodable("Home"), AnyCodable("Work")]),
            "sectionOrder": AnyCodable([AnyCodable("category:Home"), AnyCodable("ungrouped"), AnyCodable("category:Missing")]),
        ]))
        let groups = try GatewayPayloadCodec.decode(SessionsGroupsMutationResult.self, from: AnyCodable(put))
        #expect(groups.groups.map(\.name) == ["Work", "Home"])
        #expect(groups.groups.map(\.position) == [0, 1])
        #expect(groups.sectionorder == ["category:Home", "ungrouped"])

        _ = await Harness.call(server, "sessions.patch", ["key": AnyCodable("s1"), "category": AnyCodable("Work")])
        _ = await Harness.call(server, "sessions.patch", ["key": AnyCodable("s2"), "category": AnyCodable("Side")])
        let listed = try GatewayPayloadCodec.decode(
            SessionsGroupsListResult.self,
            from: AnyCodable(try Harness.payload(await Harness.call(server, "sessions.groups.list")))
        )
        #expect(listed.groups.map(\.name) == ["Work", "Home", "Side"])

        let dropping = await Harness.call(server, "sessions.groups.put", ["names": AnyCodable([AnyCodable("Home")])])
        #expect(dropping.error?.errorCode == .invalidRequest)
        #expect(dropping.error?.message.contains("\"Work\" (1)") == true)

        let renamed = try Harness.payload(await Harness.call(server, "sessions.groups.rename", ["name": AnyCodable("Work"), "to": AnyCodable("Office")]))
        #expect(renamed["updatedSessions"] == AnyCodable(1))
        #expect(await store.recordForKey("s1")?.category == "Office")

        let deleted = try Harness.payload(await Harness.call(server, "sessions.groups.delete", ["name": AnyCodable("Office")]))
        #expect(deleted["updatedSessions"] == AnyCodable(1))
        #expect(await store.recordForKey("s1") != nil)
        #expect(await store.recordForKey("s1")?.category == nil)
        #expect(await Harness.call(server, "sessions.groups.delete", ["name": AnyCodable("Office")]).error?.errorCode == .invalidRequest)

        let updated = try Harness.payload(await Harness.call(server, "sessions.groups.update", [
            "name": AnyCodable("Home"), "cwd": AnyCodable("/tmp/home"), "worktree": AnyCodable(true),
        ]))
        #expect(updated["defaults"]?.arrayValue?.first?.dictionaryValue?["cwd"] == AnyCodable("/tmp/home"))
        let relative = await Harness.call(server, "sessions.groups.update", [
            "name": AnyCodable("Home"), "cwd": AnyCodable("rel"), "worktree": AnyCodable(false),
        ])
        #expect(relative.error?.errorCode == .invalidRequest)
        let defaults = try Harness.payload(await Harness.call(server, "sessions.groups.defaults"))
        #expect(defaults["defaults"]?.arrayValue?.count == 1)
    }

    @Test
    func groupCatalogPersistsToDisk() async throws {
        let url = Harness.temporaryRoot("org-persist").appendingPathComponent("groups.json")
        let catalog = GatewaySessionGroupCatalog(fileURL: url)
        try await catalog.put(names: ["A", "B"], sectionOrder: ["category:B"], memberCounts: [:])
        _ = try await catalog.updateDefaults(name: "A", cwd: "/x", worktree: false)
        let reloaded = GatewaySessionGroupCatalog(fileURL: url)
        #expect(await reloaded.groups().map(\.name) == ["A", "B"])
        #expect(await reloaded.sectionOrder() == ["category:B"])
        #expect(await reloaded.defaults().first?.cwd == "/x")
    }

    @Test
    func runtimePatchRegistersGroupsAndEmitsSessionsChanged() async throws {
        let stack = await Harness.runtimeStack("org-runtime", turns: [])
        let events = await stack.server.events(filter: .only(.sessionsChanged))
        _ = await Harness.call(stack.server, "sessions.patch", ["key": AnyCodable("agent:main:x"), "category": AnyCodable("Research")])
        #expect(await stack.server.sessionGroups.contains("Research"))
        let frames = try await Harness.collect(events, "sessions.changed after patch") { !$0.isEmpty }
        let payload = try #require(frames.first?.payload?.dictionaryValue)
        #expect(payload["reason"] == AnyCodable("create"))
        #expect(payload["session"]?.dictionaryValue?["category"] == AnyCodable("Research"))
    }
}
