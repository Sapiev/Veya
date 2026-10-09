import XCTest

/// PBI-407: the Settings window; PBI-203: autoplay switch; PBI-205, PBI-206, PBI-207: playback and storage choices.
final class SettingsUITests: XCTestCase {
    @MainActor private func openSettings(_ scenario: Scenario = .signedIn) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(",", modifierFlags: .command)
        return app
    }

    @MainActor private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.toolbars.buttons[name]
    }

    @MainActor func testCommandCommaOpensSettingsWithEveryTab() {
        let app = openSettings()

        for name in ["General", "Playback", "Storage", "Connect", "Account", "Advanced"] {
            XCTAssertTrue(tab(app, name).waitForExistence(timeout: XCUIApplication.timeout), name)
        }
    }

    @MainActor func testPlaybackChoiceIsKeptAfterReopeningSettings() {
        let app = openSettings()
        tab(app, "Playback").click()
        let quality = app.popUpButtons["Streaming quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: XCUIApplication.timeout))

        quality.click()
        app.menuItems["Low (96 kbps)"].click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Playback").click()

        XCTAssertEqual(app.popUpButtons["Streaming quality"].value as? String, "Low (96 kbps)")
    }

    /// PBI-203: autoplay is on by default and switching it off is remembered.
    @MainActor func testAutoplaySwitchIsKeptAfterReopeningSettings() {
        let app = openSettings()
        tab(app, "Playback").click()
        let autoplay = app.descendants(matching: .any).matching(identifier: "autoplay").firstMatch
        XCTAssertTrue(autoplay.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(isOn(autoplay))

        autoplay.click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Playback").click()

        let reopened = app.descendants(matching: .any).matching(identifier: "autoplay").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(isOn(reopened))
    }

    /// Checkboxes and switches report their state as 0 or 1.
    @MainActor private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? (element.value as? String == "1")
    }

    @MainActor func testAccountSignOutReturnsToSignIn() {
        let app = openSettings()
        tab(app, "Account").click()

        app.buttons["Sign Out"].click()

        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.buttons["Sign Out"].isEnabled)
    }

    @MainActor func testResetMetadataCacheAsksBeforeClearing() {
        let app = openSettings()
        tab(app, "Storage").click()

        app.buttons["Reset Metadata Cache…"].click()
        let reset = app.sheets.buttons["Reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: XCUIApplication.timeout))
        reset.click()

        XCTAssertTrue(app.staticTexts["Metadata cache cleared."].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testAdvancedOffersLogLevels() {
        let app = openSettings()
        tab(app, "Advanced").click()

        XCTAssertTrue(app.popUpButtons["Log level"].waitForExistence(timeout: XCUIApplication.timeout))
    }
}
