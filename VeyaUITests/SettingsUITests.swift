import SystemConfiguration
import XCTest

/// PBI-407: the Settings window; PBI-203: autoplay switch; PBI-205, PBI-206, PBI-207: playback and storage choices.
/// General: window colors from the artwork, an accent color, or the accent cycling.
/// PBI-103: the cache size footer says playback survives the reconnect. PBI-309: the Spotify Web API section.
/// PBI-501: the Connect device name and the zeroconf switch.
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

    /// PBI-501: the device is named after the Mac, stays off the LAN by default, and a new name is kept.
    @MainActor func testConnectDeviceNameDefaultsToTheMacAndARenameIsKept() {
        let app = openSettings()
        tab(app, "Connect").click()
        let name = app.textFields["Device name"]
        XCTAssertTrue(name.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(name.value as? String, SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Veya")
        let zeroconf = app.toggle("Discoverable on the local network")
        XCTAssertTrue(zeroconf.exists)
        XCTAssertFalse(isOn(zeroconf))

        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Kitchen Mac\r")
        zeroconf.click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Connect").click()

        XCTAssertTrue(name.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(name.value as? String, "Kitchen Mac")
        XCTAssertTrue(isOn(app.toggle("Discoverable on the local network")))
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
        let autoplay = app.toggle("Autoplay")
        XCTAssertTrue(autoplay.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(isOn(autoplay))

        autoplay.click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Playback").click()

        let reopened = app.toggle("Autoplay")
        XCTAssertTrue(reopened.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(isOn(reopened))
    }

    @MainActor func testCyclingColorsShowsItsSpeedAndIsKeptAfterReopeningSettings() {
        let app = openSettings()
        tab(app, "General").click()
        let colors = app.popUpButtons["Window colors"]
        XCTAssertTrue(colors.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(colors.value as? String, "From the Playing Artwork")
        XCTAssertTrue(app.colorWells["Accent color"].exists)
        XCTAssertFalse(app.popUpButtons["Cycle speed"].exists)

        colors.click()
        app.menuItems["Cycle Through Colors"].click()
        let speed = app.popUpButtons["Cycle speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: XCUIApplication.timeout))
        speed.click()
        app.menuItems["Fast (15 s)"].click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "General").click()

        XCTAssertEqual(app.popUpButtons["Window colors"].value as? String, "Cycle Through Colors")
        XCTAssertEqual(app.popUpButtons["Cycle speed"].value as? String, "Fast (15 s)")
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

        app.toggle("Normalize volume").click()
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

    /// The Web API section's status line reads `value`.
    @MainActor private func showsWebAPIStatus(_ app: XCUIApplication, _ value: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'webAPIStatus' AND value == %@", value)).firstMatch
            .waitForExistence(timeout: XCUIApplication.timeout)
    }

    /// PBI-309: the Client ID is checked before connecting. The "Connect" tab shares the button's name.
    @MainActor func testWebAPIConnectNeedsAValidClientID() {
        let app = openSettings(.webAPINotConnected)
        tab(app, "Account").click()
        let field = app.textFields["Client ID"]
        XCTAssertTrue(field.waitForExistence(timeout: XCUIApplication.timeout))
        let connect = app.scrollViews.buttons["Connect"]
        XCTAssertFalse(connect.isEnabled)

        field.click()
        field.typeText("not-a-client-id")
        XCTAssertFalse(connect.isEnabled)
        XCTAssertTrue(app.staticTexts["A Client ID is 32 letters and digits (0-9, a-f)."].exists)

        field.typeKey("a", modifierFlags: .command)
        field.typeText("0123456789abcdef0123456789abcdef")
        XCTAssertTrue(connect.isEnabled)
        connect.click()

        XCTAssertTrue(showsWebAPIStatus(app, "Connected"))
        XCTAssertTrue(app.buttons["Disconnect"].exists)
    }

    /// PBI-309: a connected Web API can be disconnected.
    @MainActor func testWebAPIConnectedShowsDisconnect() {
        let app = openSettings()
        tab(app, "Account").click()
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.textFields["Client ID"].value as? String, "0123456789abcdef0123456789abcdef")
        XCTAssertTrue(showsWebAPIStatus(app, "Connected"))

        disconnect.click()

        XCTAssertTrue(showsWebAPIStatus(app, "Not connected"))
        XCTAssertFalse(disconnect.exists)
        XCTAssertTrue(app.scrollViews.buttons["Connect"].isEnabled)
    }

    @MainActor func testAdvancedOffersLogLevels() {
        let app = openSettings()
        tab(app, "Advanced").click()

        XCTAssertTrue(app.popUpButtons["Log level"].waitForExistence(timeout: XCUIApplication.timeout))
    }
}
