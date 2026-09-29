import Foundation
import Testing
@testable import OpenClawChannels

@Suite("Channel DM pairing store")
struct ChannelPairingStoreTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) {
            self.current = start
        }

        var now: Date {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.current
        }

        func advance(seconds: TimeInterval) {
            self.lock.lock()
            self.current = self.current.addingTimeInterval(seconds)
            self.lock.unlock()
        }
    }

    /// Persistence whose first load waits for a gate and whose saves can be slowed per call.
    actor SlowPersistence: ChannelPairingPersistence {
        let gate = ChannelTestGate()
        private(set) var loads = 0
        private(set) var saved: [ChannelPairingSnapshot] = []
        private var delays: [UInt64]
        private var stored: ChannelPairingSnapshot?

        init(saveDelaysNs: [UInt64] = [], initial: ChannelPairingSnapshot? = nil) {
            self.delays = saveDelaysNs
            self.stored = initial
        }

        func load() async throws -> ChannelPairingSnapshot? {
            self.loads += 1
            await self.gate.wait()
            return self.stored
        }

        private(set) var started = 0

        func save(_ snapshot: ChannelPairingSnapshot) async throws {
            self.started += 1
            let delay = self.delays.isEmpty ? 0 : self.delays.removeFirst()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            self.saved.append(snapshot)
            self.stored = snapshot
        }

        func current() -> ChannelPairingSnapshot? {
            self.stored
        }
    }

    @Test
    func concurrentFirstAccessesShareOneLoadAndKeepEveryUpdate() async throws {
        let persistence = SlowPersistence()
        let store = ChannelPairingStore(persistence: persistence)
        async let added = store.addApprovedSender(channel: .telegram, accountID: nil, senderID: "owner")
        async let pending = store.upsert(channel: .telegram, accountID: nil, senderID: "stranger")
        try await waitUntil("load started") { await persistence.gate.waitCount >= 1 }
        await persistence.gate.open()
        let (didAdd, request) = try await (added, pending)
        #expect(didAdd)
        #expect(request.created)
        #expect(await persistence.loads == 1)
        #expect(try await store.approvedSenders(channel: .telegram, accountID: nil) == ["owner"])
        #expect(try await store.list(channel: .telegram).map(\.request.id) == ["stranger"])
        let persisted = try #require(await persistence.current()?.channels["telegram"])
        #expect(persisted.allowFrom["default"] == ["owner"])
        #expect(persisted.requests.map(\.id) == ["stranger"])
    }

    @Test
    func savesLandInMutationOrderEvenWhenAnEarlierWriteIsSlow() async throws {
        let persistence = SlowPersistence(saveDelaysNs: [150_000_000, 0])
        await persistence.gate.open()
        let store = ChannelPairingStore(persistence: persistence)
        _ = try await store.approvedSenders(channel: .telegram, accountID: nil)
        let first = Task { try await store.addApprovedSender(channel: .telegram, accountID: nil, senderID: "a") }
        try await waitUntil("slow first save in flight") { await persistence.started == 1 }
        let second = Task { try await store.addApprovedSender(channel: .telegram, accountID: nil, senderID: "b") }
        _ = try await (first.value, second.value)
        // Without ordering, the slow first write ([a]) would land after the second ([a, b]).
        let persisted = try #require(await persistence.current()?.channels["telegram"])
        #expect(persisted.allowFrom["default"] == ["a", "b"])
        #expect(await persistence.saved.count == 2)
    }

    @Test
    func codesUseTheUpstreamAlphabetAndLength() async throws {
        let store = ChannelPairingStore()
        let alphabet = Set(ChannelPairingStore.codeAlphabet)
        for index in 0..<3 {
            let result = try await store.upsert(channel: .telegram, accountID: "acct-\(index)", senderID: "sender")
            #expect(result.created)
            #expect(result.code.count == 8)
            #expect(result.code.allSatisfy { alphabet.contains($0) })
            #expect(!result.code.contains { "01IO".contains($0) })
        }
        #expect(ChannelPairingStore.codeAlphabet.count == 32)
    }

    @Test
    func requestsExpireAfterOneHour() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = ChannelPairingStore(now: { clock.now })
        let first = try await store.upsert(channel: .signal, accountID: nil, senderID: "+15550001111")
        #expect(first.created)
        clock.advance(seconds: 3_599)
        #expect(try await store.list(channel: .signal).count == 1)
        clock.advance(seconds: 2)
        #expect(try await store.list(channel: .signal).isEmpty)
        let again = try await store.upsert(channel: .signal, accountID: nil, senderID: "+15550001111")
        #expect(again.created)
        #expect(again.code != first.code || again.created)
    }

    @Test
    func atMostThreePendingPerAccount() async throws {
        let store = ChannelPairingStore()
        for sender in ["a", "b", "c"] {
            #expect(try await store.upsert(channel: .discord, accountID: "main", senderID: sender).created)
        }
        let capped = try await store.upsert(channel: .discord, accountID: "main", senderID: "d")
        #expect(capped.code.isEmpty)
        #expect(capped.created == false)
        // Other accounts have their own budget.
        #expect(try await store.upsert(channel: .discord, accountID: "other", senderID: "d").created)
        #expect(try await store.list(channel: .discord, accountID: "main").count == 3)
        #expect(try await store.list(channel: .discord).count == 4)
    }

    @Test
    func approveByCodeAddsTheSenderAndDismissDoesNot() async throws {
        let store = ChannelPairingStore()
        let one = try await store.upsert(channel: .telegram, accountID: nil, senderID: "42", meta: ["name": "Ada", "empty": " "])
        let two = try await store.upsert(channel: .telegram, accountID: nil, senderID: "43")
        let listed = try await store.list(channel: .telegram)
        #expect(listed.first?.request.meta["name"] == "Ada")
        #expect(listed.first?.request.meta["empty"] == nil)
        #expect(listed.first?.request.accountID == "default")

        let approved = try await store.approve(channel: .telegram, code: one.code.lowercased())
        #expect(approved?.id == "42")
        #expect(try await store.approvedSenders(channel: .telegram, accountID: nil) == ["42"])

        let requestID = try #require(try await store.list(channel: .telegram).first?.requestID)
        #expect(requestID.count == 32)
        let dismissed = try await store.dismiss(channel: .telegram, accountID: "default", requestID: requestID)
        #expect(dismissed?.id == "43")
        #expect(try await store.approvedSenders(channel: .telegram, accountID: nil) == ["42"])
        #expect(try await store.approve(channel: .telegram, code: two.code) == nil)
        #expect(try await store.removeApproved(channel: .telegram, accountID: nil, senderID: "42"))
        #expect(try await store.approvedSenders(channel: .telegram, accountID: nil).isEmpty)
    }

    @Test
    func requestIDMatchesUpstreamDerivation() {
        let request = ChannelPairingRequest(
            id: "123",
            code: "ABCDEFGH",
            createdAt: "2026-09-28T12:00:00.000Z",
            lastSeenAt: "2026-09-28T12:00:00.000Z",
            meta: ["accountId": "default"]
        )
        // sha256("telegram\0default\0123\02026-09-28T12:00:00.000Z") → base64url, first 32 chars.
        let id = request.requestID(channel: .telegram)
        // Vector computed with upstream's node:crypto derivation.
        #expect(id == "m-jM02j6ccR3nS4VF_kzQ_326Zb2ryIt")
        #expect(id.count == 32)
        #expect(!id.contains("+") && !id.contains("/") && !id.contains("="))
        #expect(id == request.requestID(channel: .telegram))
        #expect(id != request.requestID(channel: .discord))
    }

    @Test
    func persistsToChannelPairingJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-pairing-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChannelPairingStore(stateDirectory: directory)
        let result = try await store.upsert(channel: .whatsapp, accountID: nil, senderID: "+15551230000")
        _ = try await store.approve(channel: .whatsapp, code: result.code)
        let file = directory.appendingPathComponent("channel-pairing.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let reloaded = ChannelPairingStore(stateDirectory: directory)
        #expect(try await reloaded.approvedSenders(channel: .whatsapp, accountID: "DEFAULT") == ["+15551230000"])
    }

    @Test
    func pairingReplyTextMatchesUpstreamExactly() {
        let text = ChannelPairingReply.text(
            channel: .telegram,
            idLine: ChannelPairingReply.idLine(channel: .telegram, senderID: "123"),
            code: "ABCD2345"
        )
        let expected = [
            "OpenClaw: access not configured.",
            "",
            "Your Telegram user id: 123",
            "Pairing code:",
            "```",
            "ABCD2345",
            "```",
            "",
            "Ask the bot owner to approve with:",
            "```",
            "openclaw pairing approve telegram ABCD2345",
            "```",
        ].joined(separator: "\n")
        #expect(text == expected)
    }
}
