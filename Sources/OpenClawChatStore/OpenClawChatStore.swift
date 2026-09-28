import Foundation
import GRDB
import OpenClawChatUI

/// Namespace for the optional OpenClaw offline chat store.
///
/// `OpenClawChatStore` persists chat transcripts, outbox entries, and client caches for
/// OpenClawChatUI in SQLite through GRDB. It ships as a separate product so apps that do not need
/// offline storage never compile GRDB. SwiftPM still resolves GRDB for every consumer of the
/// package. The module is Apple-only.
public enum OpenClawChatStore {
    /// Release of OpenClawKit that introduced this module surface.
    public static let moduleVersion = "2026.3.0"

    /// SQLite database engine type the store is built on. Referenced so the GRDB link is verified.
    static var databaseEngine: DatabaseQueue.Type { DatabaseQueue.self }
}
