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
