import XCTest
@testable import OpenClawiOS

@MainActor
final class OpenClawiOSAppStateTests: XCTestCase {
    func testInitialDeploymentStateIsStopped() {
        let state = OpenClawAppState()

        XCTAssertEqual(state.deploymentState, .stopped)
        XCTAssertEqual(state.statusText, "Not deployed")
        XCTAssertFalse(state.isDeployed)
    }

    func testDefaultProviderSelectionAndModelSuggestion() {
        let state = OpenClawAppState()

        XCTAssertEqual(state.selectedProvider, .openAI)
        XCTAssertEqual(state.selectedModelID, OpenClawAppState.DeployProvider.openAI.defaultModelID)
        XCTAssertEqual(state.availableProviders.count, OpenClawAppState.DeployProvider.allCases.count)
    }
}
