import Foundation

/// In-memory A2A task store (port of upstream `extensions/a2a/src/task-store.ts`).
///
/// Tasks are scoped to their owning peer; replies complete the oldest pending task of a
/// `(peer, contextId)` conversation in FIFO order. Terminal tasks are kept for 24 hours and at
/// most 500 of them are retained.
public actor A2ATaskStore {
    /// Maximum retained terminal tasks.
    public static let terminalMaxTasks = 500
    /// Terminal task retention.
    public static let terminalRetention: TimeInterval = 24 * 60 * 60
    /// Maximum status message length.
    public static let errorMaxLength = 512

    private struct Waiter {
        let continuation: CheckedContinuation<A2ATask?, Never>
        let timeout: Task<Void, Never>
    }

    private var tasks: [String: A2ATask] = [:]
    private var owners: [String: String] = [:]
    private var pendingByConversation: [String: [String]] = [:]
    private var terminalOrder: [(id: String, finishedAt: Date)] = []
    private var waiters: [String: [UUID: Waiter]] = [:]
    private let now: @Sendable () -> Date

    /// Creates a store.
    /// - Parameter now: Clock (injectable for retention tests).
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Creates a submitted task for a conversation.
    /// - Parameters:
    ///   - contextId: Context id.
    ///   - ownerPeer: Owning peer.
    /// - Returns: New task.
    public func create(contextId: String, ownerPeer: String?) -> A2ATask {
        self.pruneTerminalTasks()
        let task = A2ATask(contextId: contextId, status: A2ATaskStatus(state: .submitted, timestamp: A2AProtocol.timestamp(self.now())))
        self.tasks[task.id] = task
        if let ownerPeer {
            self.owners[task.id] = ownerPeer
        }
        self.pendingByConversation[Self.conversationKey(contextId, ownerPeer), default: []].append(task.id)
        return task
    }

    /// Returns a task visible to `ownerPeer` (all tasks when `nil`).
    /// - Parameters:
    ///   - taskId: Task id.
    ///   - ownerPeer: Requesting peer.
    /// - Returns: Task, or `nil` when missing or owned by another peer.
    public func get(_ taskId: String, ownerPeer: String? = nil) -> A2ATask? {
        self.pruneTerminalTasks()
        if let ownerPeer, self.owners[taskId] != ownerPeer {
            return nil
        }
        return self.tasks[taskId]
    }

    /// Moves a submitted task to working.
    /// - Parameter taskId: Task id.
    /// - Returns: Updated task.
    @discardableResult
    public func start(_ taskId: String) -> A2ATask? {
        guard var task = self.tasks[taskId] else { return nil }
        if task.status.state == .submitted {
            task.status = A2ATaskStatus(state: .working, timestamp: A2AProtocol.timestamp(self.now()))
            self.tasks[taskId] = task
        }
        return task
    }

    /// Whether a conversation has a pending (non-terminal) task.
    /// - Parameters:
    ///   - contextId: Context id.
    ///   - ownerPeer: Owning peer.
    /// - Returns: `true` when a reply would complete a task.
    public func hasPending(contextId: String, ownerPeer: String?) -> Bool {
        !(self.pendingByConversation[Self.conversationKey(contextId, ownerPeer)] ?? []).isEmpty
    }

    /// Completes the oldest pending task of a conversation with the reply text.
    /// - Parameters:
    ///   - contextId: Context id.
    ///   - text: Reply text.
    ///   - ownerPeer: Owning peer.
    /// - Returns: Completed task, or `nil` when none was pending.
    @discardableResult
    public func completeNext(contextId: String, text: String?, ownerPeer: String?) -> A2ATask? {
        let key = Self.conversationKey(contextId, ownerPeer)
        guard var queue = self.pendingByConversation[key], !queue.isEmpty else { return nil }
        let nextID = queue.removeFirst()
        self.pendingByConversation[key] = queue.isEmpty ? nil : queue
        guard var task = self.tasks[nextID], !task.status.state.isTerminal else { return nil }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let text {
            task.artifacts = [A2AArtifact(parts: [.text(text)])]
        }
        task.status = A2ATaskStatus(
            state: .completed,
            timestamp: A2AProtocol.timestamp(self.now()),
            message: trimmed.isEmpty ? self.statusMessage(contextId: contextId, text: "Agent completed without reply text") : nil
        )
        return self.finish(task)
    }

    /// Fails a task.
    /// - Parameters:
    ///   - taskId: Task id.
    ///   - reason: Failure reason.
    /// - Returns: Updated task.
    @discardableResult
    public func fail(_ taskId: String, reason: String) -> A2ATask? {
        self.finish(taskId, state: .failed, reason: reason)
    }

    /// Rejects a task.
    /// - Parameters:
    ///   - taskId: Task id.
    ///   - reason: Rejection reason.
    /// - Returns: Updated task.
    @discardableResult
    public func reject(_ taskId: String, reason: String) -> A2ATask? {
        self.finish(taskId, state: .rejected, reason: reason)
    }

    /// Waits until a task is terminal or the timeout elapses.
    /// - Parameters:
    ///   - taskId: Task id.
    ///   - timeoutMs: Timeout in milliseconds.
    /// - Returns: The task (terminal, or still working on timeout).
    public func wait(_ taskId: String, timeoutMs: Int) async -> A2ATask? {
        guard let task = self.get(taskId), !task.status.state.isTerminal else {
            return self.get(taskId)
        }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: ChannelAsync.nanoseconds(milliseconds: timeoutMs))
                await self?.expireWaiter(taskId: taskId, waiterID: waiterID)
            }
            self.waiters[taskId, default: [:]][waiterID] = Waiter(continuation: continuation, timeout: timeout)
        }
    }

    /// Resolves every waiter and clears the store.
    public func stop() {
        for (taskId, entries) in self.waiters {
            for waiter in entries.values {
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: self.tasks[taskId])
            }
        }
        self.waiters.removeAll()
        self.pendingByConversation.removeAll()
        self.terminalOrder.removeAll()
        self.owners.removeAll()
        self.tasks.removeAll()
    }

    /// Number of stored tasks (diagnostics and tests).
    public var count: Int {
        self.tasks.count
    }

    private func expireWaiter(taskId: String, waiterID: UUID) {
        guard let waiter = self.waiters[taskId]?.removeValue(forKey: waiterID) else { return }
        if self.waiters[taskId]?.isEmpty == true {
            self.waiters[taskId] = nil
        }
        waiter.continuation.resume(returning: self.tasks[taskId])
    }

    private func finish(_ taskId: String, state: A2ATaskState, reason: String) -> A2ATask? {
        guard var task = self.tasks[taskId] else { return nil }
        guard !task.status.state.isTerminal else { return task }
        let key = Self.conversationKey(task.contextId, self.owners[taskId])
        if var queue = self.pendingByConversation[key] {
            queue.removeAll { $0 == taskId }
            self.pendingByConversation[key] = queue.isEmpty ? nil : queue
        }
        task.status = A2ATaskStatus(
            state: state,
            timestamp: A2AProtocol.timestamp(self.now()),
            message: self.statusMessage(contextId: task.contextId, text: reason)
        )
        return self.finish(task)
    }

    private func finish(_ task: A2ATask) -> A2ATask {
        self.tasks[task.id] = task
        self.terminalOrder.append((task.id, self.now()))
        if let entries = self.waiters.removeValue(forKey: task.id) {
            for waiter in entries.values {
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: task)
            }
        }
        self.pruneTerminalTasks()
        return task
    }

    private func pruneTerminalTasks() {
        let expiresBefore = self.now().addingTimeInterval(-Self.terminalRetention)
        while let first = self.terminalOrder.first,
              first.finishedAt <= expiresBefore || self.terminalOrder.count > Self.terminalMaxTasks
        {
            self.terminalOrder.removeFirst()
            self.tasks[first.id] = nil
            self.owners[first.id] = nil
        }
    }

    private func statusMessage(contextId: String, text: String) -> A2AMessage {
        A2AMessage(contextId: contextId, role: .agent, parts: [.text(String(text.prefix(Self.errorMaxLength)))])
    }

    private static func conversationKey(_ contextId: String, _ ownerPeer: String?) -> String {
        ownerPeer.map { "\($0)\u{0}\(contextId)" } ?? contextId
    }
}
