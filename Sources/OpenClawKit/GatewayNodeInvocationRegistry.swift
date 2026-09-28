import Foundation

/// Synchronous invocation ownership, isolated by the containing ``GatewayNodeSession`` actor.
///
/// Tracks the node commands whose device side effects must be retired with their route:
/// `computer.act`, `camera.ptz.control` and every `talk.ptt.*` command wait for route teardown;
/// `system.notify`, `chat.push` and `watch.notify` are fenced but never hold a replacement route
/// open (permission callbacks can ignore cancellation).
struct GatewayNodeInvocationRegistry {
    typealias Cleanup = (id: UUID, task: Task<BridgeInvokeResponse, Never>)

    static let computerActCommand = "computer.act"
    static let cameraPTZControlCommand = "camera.ptz.control"

    private struct Invocation {
        enum State {
            case pending
            case cancelled
            case running(Task<BridgeInvokeResponse, Never>)
        }

        let requestID: String
        let admissionGeneration: UInt64
        let waitsForRouteTeardown: Bool
        var state: State = .pending

        var task: Task<BridgeInvokeResponse, Never>? {
            if case let .running(task) = self.state {
                task
            } else { nil }
        }

        mutating func cancel() {
            switch self.state {
            case .pending: self.state = .cancelled
            case let .running(task): task.cancel()
            case .cancelled: break
            }
        }
    }

    private var invocations: [UUID: Invocation] = [:]

    static func waitsForRouteTeardown(command: String) -> Bool {
        command == Self.computerActCommand ||
            command == Self.cameraPTZControlCommand ||
            OpenClawTalkCommand(rawValue: command) != nil ||
            command.hasPrefix("talk.ptt.")
    }

    mutating func register(requestID: String, command: String, admissionGeneration: UInt64) -> UUID? {
        let waitsForRouteTeardown = Self.waitsForRouteTeardown(command: command)
        guard waitsForRouteTeardown || command == OpenClawSystemCommand.notify.rawValue ||
            command == OpenClawChatCommand.push.rawValue || command == OpenClawWatchCommand.notify.rawValue
        else { return nil }
        let id = UUID()
        self.invocations[id] = Invocation(
            requestID: requestID,
            admissionGeneration: admissionGeneration,
            waitsForRouteTeardown: waitsForRouteTeardown)
        return id
    }

    /// The synchronous factory retains the session's actor isolation when creating
    /// its task; cancellation cannot interleave between admission and registration.
    mutating func start(
        id: UUID,
        makeTask: () -> Task<BridgeInvokeResponse, Never>) -> Task<BridgeInvokeResponse, Never>?
    {
        guard !Task.isCancelled, case .pending? = self.invocations[id]?.state else { return nil }
        let task = makeTask()
        self.invocations[id]?.state = .running(task)
        return task
    }

    mutating func finish(_ id: UUID) {
        self.invocations.removeValue(forKey: id)
    }

    mutating func discardPending(_ id: UUID?) {
        // A joined computer receipt never starts another operation. Its pending
        // admission ends here; running operations retain cleanup ownership.
        if let id, self.invocations[id]?.task == nil {
            self.finish(id)
        }
    }

    mutating func cancel(admissionGeneration: UInt64) -> [Cleanup] {
        var cleanup: [Cleanup] = []
        for (id, var invoke) in self.invocations where invoke.admissionGeneration == admissionGeneration {
            invoke.cancel()
            if invoke.waitsForRouteTeardown, let task = invoke.task {
                self.invocations[id] = invoke
                cleanup.append((id, task))
            } else {
                // Notification permission callbacks can ignore cancellation. Fence
                // their effect, but never make them hold replacement routes open.
                self.finish(id)
            }
        }
        return cleanup
    }

    mutating func cancel(requestID: String, admissionGeneration: UInt64) {
        for (id, invoke) in self.invocations
            where invoke.requestID == requestID && invoke.admissionGeneration == admissionGeneration
        {
            self.invocations[id]?.cancel()
        }
    }

    var count: Int {
        self.invocations.count
    }
}
