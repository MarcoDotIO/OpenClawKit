import Testing
import OpenClawAppIntents
import OpenClawChatStore
import OpenClawMCP
import OpenClawNativeState

@Suite("Package skeleton")
struct PackageSkeletonTests {
    @Test
    func newProductsLinkAndReportTheirRelease() {
        #expect(OpenClawNativeState.moduleVersion == "2026.3.0")
        #expect(OpenClawMCP.moduleVersion == "2026.3.0")
        #expect(OpenClawAppIntents.moduleVersion == "2026.3.0")
        #expect(OpenClawChatStore.moduleVersion == "2026.3.0")
    }

    @Test
    func mcpStdioTransportAvailabilityMatchesPlatform() {
        #if os(macOS) || os(Linux)
        #expect(OpenClawMCP.supportsStdioTransport)
        #else
        #expect(!OpenClawMCP.supportsStdioTransport)
        #endif
    }

    @Test
    func experimentalModelDelegationFollowsPackageTrait() {
        // Package traits define a compilation condition for every target of the root package,
        // so the test target sees the same flag as OpenClawAppIntents.
        #if ExperimentalAppleModelDelegation
        #expect(OpenClawAppIntents.isExperimentalModelDelegationEnabled)
        #else
        #expect(!OpenClawAppIntents.isExperimentalModelDelegationEnabled)
        #endif
    }
}
