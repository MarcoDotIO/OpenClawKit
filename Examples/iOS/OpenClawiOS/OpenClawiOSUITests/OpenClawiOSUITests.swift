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

    func testKeyboardDoneButtonDismissesOnModelsTab() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Models"].tap()
        let modelField = app.textFields["Model ID"]
        XCTAssertTrue(modelField.waitForExistence(timeout: 10))
        modelField.tap()
        modelField.typeText("kbd-test")

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        self.waitForDisappearance(of: doneButton)
    }

    func testInteractiveScrollDismissesKeyboardOnDeployTab() throws {
        let app = XCUIApplication()
        app.launch()

        let channelField = app.textFields["Discord Channel ID"]
        XCTAssertTrue(channelField.waitForExistence(timeout: 10))
        channelField.tap()
        channelField.typeText("12345")

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        app.collectionViews.firstMatch.swipeDown()
        self.waitForDisappearance(of: doneButton)
    }

    func testSkillPickerIsVisibleOnChatTab() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Chat"].tap()
        let picker = app.buttons["Skill: Automatic"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
    }

    func testAttachmentImportButtonIsVisibleOnChatTab() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Chat"].tap()
        let attachmentButton = app.buttons["chat-attach-file-button"]
        XCTAssertTrue(attachmentButton.waitForExistence(timeout: 10))
    }

    func testLiveActivitySectionIsVisibleOnDeployTab() throws {
        let app = XCUIApplication()
        app.launch()

        let sectionTitle = app.staticTexts["Live Activity"]
        XCTAssertTrue(sectionTitle.waitForExistence(timeout: 10))
        let liveStatus = app.staticTexts["live-activity-status-text"]
        XCTAssertTrue(liveStatus.exists)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(element.exists)
    }
}
