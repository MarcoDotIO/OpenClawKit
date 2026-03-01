import XCTest

@MainActor
final class OpenClawiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMainTabsAreVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        let tabBarVisible = tabBar.waitForExistence(timeout: 10)
        let tabCount = tabBar.buttons.count
        let deployTitleVisible = app.navigationBars["Deploy"].waitForExistence(timeout: 5)
        let deployTabVisible = tabBar.buttons["Deploy"].exists
        let chatTabVisible = tabBar.buttons["Chat"].exists
        let modelsTabVisible = tabBar.buttons["Models"].exists
        let skillsTabVisible = tabBar.buttons["Skills"].exists
        let moreTabVisible = tabBar.buttons["More"].exists

        XCTAssertTrue(tabBarVisible)
        XCTAssertGreaterThanOrEqual(tabCount, 5)
        XCTAssertTrue(deployTitleVisible)
        XCTAssertTrue(deployTabVisible)
        XCTAssertTrue(chatTabVisible)
        XCTAssertTrue(modelsTabVisible)
        XCTAssertTrue(skillsTabVisible)
        XCTAssertTrue(moreTabVisible)
    }

    func testDeployStatusStartsAsNotDeployed() throws {
        let app = XCUIApplication()
        app.launch()

        let deploymentSectionVisible = app.staticTexts["Deployment Status"].waitForExistence(timeout: 10)
        let stoppedStatusVisible = app.staticTexts["Stopped"].exists

        XCTAssertTrue(deploymentSectionVisible)
        XCTAssertTrue(stoppedStatusVisible)
    }

    func testTelegramFieldsAreVisibleOnDeployTab() throws {
        let app = XCUIApplication()
        app.launch()

        let telegramTokenVisible = app.secureTextFields["Telegram Bot Token"].waitForExistence(timeout: 10)
        let telegramChatIDVisible = app.textFields["Telegram Chat ID (optional)"].exists

        XCTAssertTrue(telegramTokenVisible)
        XCTAssertTrue(telegramChatIDVisible)
    }
}
