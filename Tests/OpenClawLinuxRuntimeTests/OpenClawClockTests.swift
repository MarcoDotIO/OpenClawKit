import Foundation
import Testing
@testable import OpenClawCore

@Suite("OpenClaw millisecond clock")
struct OpenClawClockTests {
    @Test
    func nowIsInt64MillisecondsBeyondInt32() {
        let now = OpenClawClock.nowMs()
        // Current epoch milliseconds are far above Int32.max (the arm64_32 `Int` range).
        #expect(now > Int64(Int32.max))
        let reference = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        #expect(abs(reference - now) < Int64(60_000))
    }

    @Test
    func convertsDatesBothWaysAndClampsNonFiniteValues() {
        let date = Date(timeIntervalSince1970: 4_102_444_800.123)
        #expect(OpenClawClock.ms(date) == Int64(4_102_444_800_123))
        #expect(OpenClawClock.date(fromMs: Int64(4_102_444_800_123)).timeIntervalSince1970 == 4_102_444_800.123)
        #expect(OpenClawClock.ms(Date.distantFuture) > Int64(0))
        #expect(OpenClawClock.ms(Date(timeIntervalSince1970: .infinity)) == Int64.max)
    }

    @Test
    func pairingRecordsCarryInt64ApprovalTimestamps() async {
        let security = SecurityRuntime()
        await security.approveDevice(deviceID: "watch", role: "node", token: "t")
        let record = await security.pairedDevice("watch")
        #expect((record?.approvedAtMs ?? 0) > Int64(Int32.max))
        let manual = PairingRecord(deviceID: "d", role: "r", token: "t", approvedAtMs: Int64(4_102_444_800_000))
        #expect(manual.approvedAtMs == Int64(4_102_444_800_000))
    }
}
