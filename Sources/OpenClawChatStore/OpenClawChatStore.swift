import Foundation
import GRDB
import OpenClawChatUI

/// Namespace for the optional OpenClaw offline chat store.
///
/// `OpenClawChatStore` persists chat transcripts, outbox entries, and client caches for
/// OpenClawChatUI in SQLite through GRDB. It ships as a separate product so apps that do not need
/// offline storage never compile GRDB. SwiftPM still resolves GRDB for every consumer of the
/// package. The module is Apple-only.
///
/// Entry points:
/// - ``OpenClawClientDatabases``: one installation-wide container (`gateway-cache.sqlite` plus
///   `client-state.sqlite`) for every paired gateway.
/// - ``OpenClawChatSQLiteTranscriptCache``: the gateway-scoped transcript cache and durable command
///   outbox handed to `OpenClawChatViewModel`.
/// - ``OpenClawWatchMessageJournal``: the phone-side ledger for Watch-originated chat commands.
///
/// Pin the transport to the same gateway id as the store: the outbox only replays through a
/// transport whose `gatewayStableID` matches, so queued commands never reach another gateway.
///
/// ```swift
/// let databases = try OpenClawClientDatabases(
///     directoryURL: OpenClawClientDatabases.defaultDirectoryURL())
/// let store = databases.store(gatewayID: gatewayStableID)
/// let transport = OpenClawGatewaySessionChatTransport(
///     gateway: session,
///     gatewayStableID: gatewayStableID)
/// let viewModel = OpenClawChatViewModel(
///     sessionKey: "main",
///     transport: transport,
///     transcriptCache: store,
///     outbox: store)
/// ```
public enum OpenClawChatStore {
    /// Release of OpenClawKit that introduced this module surface.
    public static let moduleVersion = "2026.3.0"

    /// SQLite database engine type the store is built on. Referenced so the GRDB link is verified.
    static var databaseEngine: DatabaseQueue.Type { DatabaseQueue.self }
}
