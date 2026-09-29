import Foundation
import Testing
@testable import OpenClawKit

@Suite("Run progress")
struct RunProgressTests {
    private func event(_ name: String) -> RuntimeDiagnosticEvent {
        RuntimeDiagnosticEvent(subsystem: "runtime", name: name, runID: "run-1", sessionKey: "main")
    }

    private func milestones(for progress: OpenClawRunProgress) -> [Int] {
        var values: [Int] = [progress.completedUnitCount]
        for name in [
            "run.started", "model.call.started", "model.stream.chunk", "model.call.completed",
            "tool.started", "tool.completed", "model.call.started", "run.completed",
        ] {
            progress.record(self.event(name))
            values.append(progress.completedUnitCount)
        }
        return values
    }

    @Test
    func legacyBackingFollowsTheBudget() {
        let progress = OpenClawRunProgress(backing: .legacyProgress)
        #expect(!progress.usesProgressManager)
        let attached = Progress(totalUnitCount: 0)
        progress.attach(to: attached)
        #expect(attached.totalUnitCount == 100)

        #expect(self.milestones(for: progress) == [0, 5, 5, 20, 65, 77, 83, 83, 100])
        #expect(progress.phase == .completed)
        #expect(progress.isFinished)
        #expect(attached.completedUnitCount == 100)
        #expect(progress.fractionCompleted == 1)
    }

    @Test
    func legacyAttachMirrorsIntoCustomTotals() {
        let progress = OpenClawRunProgress(backing: .legacyProgress)
        let attached = Progress(totalUnitCount: 10)
        progress.attach(to: attached)
        progress.record(self.event("run.started"))
        progress.completeModelCall()
        #expect(attached.completedUnitCount == 7) // 65 of 100 -> 6.5 of 10, rounded
        progress.advance(to: .failed)
        #expect(attached.completedUnitCount == 10)
    }

    @Test
    func progressIsMonotonicAndStopsAtTerminalPhases() {
        let progress = OpenClawRunProgress(backing: .legacyProgress)
        progress.advance(to: .streaming, fraction: 0.5)
        #expect(progress.completedUnitCount == 35)
        progress.advance(to: .streaming, fraction: 0.1)
        #expect(progress.completedUnitCount == 35)
        progress.advance(toFractionCompleted: 0.8, phase: .toolRunning)
        #expect(progress.completedUnitCount == 80)
        progress.advance(toFractionCompleted: 0.4, phase: .streaming)
        #expect(progress.completedUnitCount == 80)
        progress.advance(to: .aborted)
        #expect(progress.completedUnitCount == 100)
        #expect(progress.phase == .aborted)
        progress.advance(to: .running)
        #expect(progress.phase == .aborted)
    }

    @Test
    func progressManagerBackingDrivesAttachedProgressOnOS27() {
        let progress = OpenClawRunProgress()
        #if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else {
            #expect(!progress.usesProgressManager)
            return
        }
        #expect(progress.usesProgressManager)
        let manager = progress.progressManager
        #expect(manager?.totalCount == 100)
        let attached = Progress(totalUnitCount: 100)
        progress.attach(to: attached)
        #expect(self.milestones(for: progress) == [0, 5, 5, 20, 65, 77, 83, 83, 100])
        #expect(manager?.completedCount == 100)
        #expect(manager?.isFinished == true)
        #expect(abs(attached.fractionCompleted - 1) < 0.0001)
        #else
        #expect(!progress.usesProgressManager)
        #endif
    }

    @Test
    func progressManagerReportsIntermediateFractions() {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        let progress = OpenClawRunProgress()
        let attached = Progress(totalUnitCount: 100)
        progress.attach(to: attached)
        progress.record(self.event("run.started"))
        progress.record(self.event("model.stream.chunk"))
        #expect(abs(attached.fractionCompleted - 0.2) < 0.0001)
        #expect(abs((progress.progressManager?.fractionCompleted ?? 0) - 0.2) < 0.0001)
        #endif
    }

    @Test
    func terminalPhasesAreTerminal() {
        #expect(OpenClawRunPhase.allCases.filter(\.isTerminal) == [.completed, .failed, .aborted])
    }
}
