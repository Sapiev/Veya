import XCTest

/// PBI-407: the Settings window; PBI-203: autoplay switch; PBI-205, PBI-206, PBI-207: playback and storage choices.
/// PBI-103: the cache size footer says playback survives the reconnect.
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

    /// Grouped forms draw a toggle as a switch or a checkbox depending on the macOS version.
    @MainActor private func toggle(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.checkBox, .switch].map(\.rawValue)
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND label BEGINSWITH %@", types, label)).firstMatch
    }

    /// Checkboxes and switches report their state as 0 or 1.
    @MainActor private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? (element.value as? String == "1")
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
        let autoplay = toggle(app, "Autoplay")
        XCTAssertTrue(autoplay.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(isOn(autoplay))

        autoplay.click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Playback").click()

        let reopened = toggle(app, "Autoplay")
        XCTAssertTrue(reopened.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(isOn(reopened))
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

    /// PBI-207: Storage offers the cache size and clears downloaded audio after asking.
    @MainActor func testClearAudioCacheAsksBeforeClearing() {
        let app = openSettings()
        tab(app, "Storage").click()
        XCTAssertTrue(app.popUpButtons["Audio cache size"].waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Clear Audio Cache…"].click()
        let clear = app.sheets.buttons["Clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: XCUIApplication.timeout))
        clear.click()

        XCTAssertTrue(app.staticTexts["Audio cache cleared."].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// PBI-205, PBI-206: normalisation presets follow the toggle; the device list starts with the system default.
    @MainActor func testLoudnessFollowsNormalizeAndOutputOffersSystemDefault() {
        let app = openSettings()
        tab(app, "Playback").click()
        let loudness = app.popUpButtons["Loudness"]
        XCTAssertTrue(loudness.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(loudness.isEnabled)

        toggle(app, "Normalize volume").click()
        XCTAssertFalse(loudness.isEnabled)

        let output = app.popUpButtons["Output device"]
        XCTAssertEqual(output.value as? String, "System Default")
    }

    @MainActor func testCacheSizeFooterSaysPlaybackResumesAfterReconnect() {
        let app = openSettings()
        tab(app, "Storage").click()

        let footer = "Changing the size reconnects to Spotify; the current track picks up where it was."
        XCTAssertTrue(app.staticTexts[footer].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testAdvancedOffersLogLevels() {
        let app = openSettings()
        tab(app, "Advanced").click()

        XCTAssertTrue(app.popUpButtons["Log level"].waitForExistence(timeout: XCUIApplication.timeout))
    }
}
