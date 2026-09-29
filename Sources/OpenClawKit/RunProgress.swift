import Foundation
import OpenClawCore

/// Coarse phases of an agent run, shared by App Intents, Live Activities and background tasks.
public enum OpenClawRunPhase: String, Sendable, Codable, CaseIterable {
    /// Accepted but not started.
    case queued
    /// Running (model call in flight or preparing).
    case running
    /// A tool call is executing.
    case toolRunning
    /// Assistant output is streaming.
    case streaming
    /// Finished successfully.
    case completed
    /// Finished with an error.
    case failed
    /// Cancelled by the user or the system.
    case aborted

    /// Whether the phase ends the run.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .aborted:
            return true
        case .queued, .running, .toolRunning, .streaming:
            return false
        }
    }
}

/// Structured progress for one agent run, on a fixed 100-unit budget.
///
/// Budget: queued 5, model call 60, tools 25, finalize 10. Progress is monotonic: model streaming
/// advances within the model budget, each tool event advances halfway through the remaining tool
/// budget, and a terminal phase completes the run.
///
/// On iOS/macOS/tvOS/watchOS/visionOS 27 the progress is backed by Foundation's `ProgressManager`
/// (observable, composable through `Subprogress`) and ``attach(to:)`` adds its reporter as a child
/// of a legacy `Progress` (for example `LongRunningIntent.progress` or
/// `BGContinuedProcessingTask.progress`). Earlier systems update attached `Progress` objects'
/// `completedUnitCount` directly.
public final class OpenClawRunProgress: @unchecked Sendable {
    /// How the progress is backed.
    public enum Backing: Sendable, Equatable {
        /// `ProgressManager` on OS 27, legacy `Progress` updates otherwise.
        case automatic
        /// Always update attached `Progress` objects directly.
        case legacyProgress
    }

    /// Total units of the run budget.
    public static let totalUnitCount = 100
    /// Units completed once the run leaves the queue.
    public static let queuedBudget = 5
    /// Units covered by the model call.
    public static let modelBudget = 60
    /// Units covered by tool calls.
    public static let toolBudget = 25
    /// Units covered by finalization.
    public static let finalizeBudget = 10

    private static let modelEnd = queuedBudget + modelBudget
    private static let toolEnd = modelEnd + toolBudget

    private let lock = NSLock()
    private var completed = 0
    private var currentPhase: OpenClawRunPhase = .queued
    private var attached: [Progress] = []
    private let manager: (any Sendable)?

    /// Creates run progress.
    /// - Parameter backing: Backing strategy.
    public init(backing: Backing = .automatic) {
        var manager: (any Sendable)?
        #if compiler(>=6.4)
        if backing == .automatic, #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            manager = ProgressManager(totalCount: Self.totalUnitCount)
        }
        #endif
        self.manager = manager
    }

    /// Whether a Foundation `ProgressManager` backs this progress.
    public var usesProgressManager: Bool {
        self.manager != nil
    }

    #if compiler(>=6.4)
    /// Foundation progress manager backing this run (OS 27, ``Backing/automatic`` only).
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    public var progressManager: ProgressManager? {
        self.manager as? ProgressManager
    }
    #endif

    /// Completed units (0...100).
    public var completedUnitCount: Int {
        self.lock.withLock { self.completed }
    }

    /// Completed fraction (0...1).
    public var fractionCompleted: Double {
        Double(self.completedUnitCount) / Double(Self.totalUnitCount)
    }

    /// Current phase.
    public var phase: OpenClawRunPhase {
        self.lock.withLock { self.currentPhase }
    }

    /// Whether the run reached a terminal phase.
    public var isFinished: Bool {
        self.phase.isTerminal
    }

    /// Drives a legacy `Progress` from this run.
    ///
    /// Sets `totalUnitCount` to 100 when the progress is indeterminate, then either adds the
    /// `ProgressManager` reporter as a child (OS 27) or mirrors `completedUnitCount`.
    /// - Parameter progress: Progress to drive.
    public func attach(to progress: Progress) {
        if progress.totalUnitCount <= 0 {
            progress.totalUnitCount = Int64(Self.totalUnitCount)
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
           let manager = self.manager as? ProgressManager
        {
            progress.addChild(manager.reporter, withPendingUnitCount: Int(progress.totalUnitCount))
            return
        }
        #endif
        let completed: Int = self.lock.withLock {
            self.attached.append(progress)
            return self.completed
        }
        Self.mirror(completed, into: progress)
    }

    /// Advances to a phase.
    /// - Parameters:
    ///   - phase: New phase.
    ///   - fraction: Optional fraction within the phase budget (streaming: share of the model budget).
    public func advance(to phase: OpenClawRunPhase, fraction: Double? = nil) {
        self.update { current, completed in
            guard !current.isTerminal else { return }
            switch phase {
            case .queued:
                break
            case .running:
                completed = max(completed, Self.queuedBudget)
            case .streaming:
                let floor = max(completed, Self.queuedBudget)
                if let fraction, fraction.isFinite {
                    let clamped = min(1, max(0, fraction))
                    completed = max(floor, Self.queuedBudget + Int((clamped * Double(Self.modelBudget)).rounded(.down)))
                } else {
                    completed = Self.step(from: floor, toward: Self.modelEnd, divisor: 4)
                }
            case .toolRunning:
                let floor = max(completed, Self.modelEnd)
                if let fraction, fraction.isFinite {
                    let clamped = min(1, max(0, fraction))
                    completed = max(floor, Self.modelEnd + Int((clamped * Double(Self.toolBudget)).rounded(.down)))
                } else {
                    completed = Self.step(from: floor, toward: Self.toolEnd, divisor: 2)
                }
            case .completed, .failed, .aborted:
                completed = Self.totalUnitCount
            }
            current = phase
        }
    }

    /// Mirrors an externally computed overall fraction (for example from a run event stream).
    /// - Parameters:
    ///   - fractionCompleted: Overall completed fraction (0...1); progress never moves backwards.
    ///   - phase: Phase reported with the fraction.
    public func advance(toFractionCompleted fractionCompleted: Double, phase: OpenClawRunPhase) {
        guard fractionCompleted.isFinite else {
            self.advance(to: phase)
            return
        }
        self.update { current, completed in
            guard !current.isTerminal else { return }
            if phase.isTerminal {
                completed = Self.totalUnitCount
            } else {
                let clamped = min(1, max(0, fractionCompleted))
                completed = max(completed, Int((clamped * Double(Self.totalUnitCount)).rounded(.down)))
            }
            current = phase
        }
    }

    /// Marks the model call as finished (the model budget is complete).
    public func completeModelCall() {
        self.update { current, completed in
            guard !current.isTerminal else { return }
            completed = max(completed, Self.modelEnd)
        }
    }

    /// Applies a runtime diagnostics event.
    ///
    /// `run.started`/`model.call.started` → running, `model.stream.chunk` → streaming,
    /// `model.call.completed` → model budget done, `tool.call.*`/`tool.*` → tools,
    /// `run.completed` → completed, `run.failed` → failed. Other events are ignored.
    /// - Parameter event: Diagnostics event.
    public func record(_ event: RuntimeDiagnosticEvent) {
        guard event.subsystem == "runtime" else { return }
        switch event.name {
        case "run.started", "model.call.started":
            self.advance(to: .running)
        case "model.stream.chunk":
            self.advance(to: .streaming)
        case "model.call.completed":
            self.completeModelCall()
        case "tool.call.started", "tool.started", "tool.call.completed", "tool.completed":
            self.advance(to: .toolRunning)
        case "run.completed":
            self.advance(to: .completed)
        case "run.failed":
            self.advance(to: .failed)
        default:
            break
        }
    }

    private static func step(from current: Int, toward target: Int, divisor: Int) -> Int {
        let remaining = target - current
        guard remaining > 1 else { return current }
        return current + max(1, remaining / divisor)
    }

    private func update(_ body: (inout OpenClawRunPhase, inout Int) -> Void) {
        let (delta, completed, attached): (Int, Int, [Progress]) = self.lock.withLock {
            let before = self.completed
            body(&self.currentPhase, &self.completed)
            self.completed = min(Self.totalUnitCount, max(before, self.completed))
            return (self.completed - before, self.completed, self.attached)
        }
        guard delta > 0 else { return }
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
           let manager = self.manager as? ProgressManager
        {
            manager.complete(count: delta)
        }
        #endif
        for progress in attached {
            Self.mirror(completed, into: progress)
        }
    }

    private static func mirror(_ completed: Int, into progress: Progress) {
        let total = max(1, progress.totalUnitCount)
        progress.completedUnitCount = Int64((Double(completed) / Double(Self.totalUnitCount) * Double(total)).rounded())
    }
}
