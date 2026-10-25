import SystemConfiguration
import XCTest

/// PBI-407: the Settings window; PBI-203: autoplay switch; PBI-205, PBI-206, PBI-207: playback and storage choices.
/// General: window colors from the artwork, an accent color, or the accent cycling.
/// PBI-103: the cache size footer says playback survives the reconnect. PBI-309: the Spotify Web API section.
/// PBI-501: the Connect device name and the zeroconf switch. PBI-208: the crossfade slider.
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

    /// One launch walks every tab: PBI-407 tabs, PBI-501 Connect name and zeroconf, PBI-203 autoplay, PBI-205/206 playback
    /// and output, PBI-207 and PBI-103 Storage, PBI-309 Web API disconnect; Sign Out runs last because it ends the session.
    @MainActor func testSettingsTabsKeepTheirChoicesAndStorageAccountAndAdvancedWork() {
        let app = openSettings()

        // Command-comma opens Settings with every tab.
        for name in ["General", "Playback", "Storage", "Connect", "Account", "Advanced"] {
            XCTAssertTrue(tab(app, name).waitForExistence(timeout: XCUIApplication.timeout), name)
        }

        // PBI-501: the device is named after the Mac, stays off the LAN by default, and a new name is kept.
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

        // Playback: streaming quality and autoplay (PBI-203: on by default) are changed.
        tab(app, "Playback").click()
        let quality = app.popUpButtons["Streaming quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: XCUIApplication.timeout))
        quality.click()
        app.menuItems["Low (96 kbps)"].click()
        let autoplay = app.toggle("Autoplay")
        XCTAssertTrue(autoplay.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(isOn(autoplay))
        autoplay.click()

        // PBI-205, PBI-206: normalisation presets follow the toggle; the device list starts with the system default.
        let loudness = app.popUpButtons["Loudness"]
        XCTAssertTrue(loudness.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(loudness.isEnabled)
        app.toggle("Normalize volume").click()
        XCTAssertFalse(loudness.isEnabled)
        XCTAssertEqual(app.popUpButtons["Output device"].value as? String, "System Default")

        // General: cycling colors shows its speed.
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

        // Every choice is kept after reopening Settings.
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Connect").click()
        XCTAssertTrue(name.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(name.value as? String, "Kitchen Mac")
        XCTAssertTrue(isOn(app.toggle("Discoverable on the local network")))
        tab(app, "Playback").click()
        XCTAssertEqual(app.popUpButtons["Streaming quality"].value as? String, "Low (96 kbps)")
        let reopened = app.toggle("Autoplay")
        XCTAssertTrue(reopened.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(isOn(reopened))
        tab(app, "General").click()
        XCTAssertEqual(app.popUpButtons["Window colors"].value as? String, "Cycle Through Colors")
        XCTAssertEqual(app.popUpButtons["Cycle speed"].value as? String, "Fast (15 s)")

        // PBI-207, PBI-103: Storage offers the cache size and asks before clearing.
        tab(app, "Storage").click()
        let footer = "Changing the size reconnects to Spotify; the current track picks up where it was."
        XCTAssertTrue(app.staticTexts[footer].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.popUpButtons["Audio cache size"].waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Reset Metadata Cache…"].click()
        let reset = app.sheets.buttons["Reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: XCUIApplication.timeout))
        reset.click()
        XCTAssertTrue(app.staticTexts["Metadata cache cleared."].waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Clear Audio Cache…"].click()
        let clear = app.sheets.buttons["Clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: XCUIApplication.timeout))
        clear.click()
        XCTAssertTrue(app.staticTexts["Audio cache cleared."].waitForExistence(timeout: XCUIApplication.timeout))

        // Advanced offers log levels.
        tab(app, "Advanced").click()
        XCTAssertTrue(app.popUpButtons["Log level"].waitForExistence(timeout: XCUIApplication.timeout))

        // PBI-309: a connected Web API can be disconnected.
        tab(app, "Account").click()
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.textFields["Client ID"].value as? String, "0123456789abcdef0123456789abcdef")
        XCTAssertTrue(showsWebAPIStatus(app, "Connected"))
        disconnect.click()
        XCTAssertTrue(showsWebAPIStatus(app, "Not connected"))
        XCTAssertTrue(disconnect.waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.scrollViews.buttons["Connect"].isEnabled)

        // Sign Out returns to sign in (last).
        app.buttons["Sign Out"].click()
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.buttons["Sign Out"].isEnabled)
    }

    /// The Web API section's status line reads `value`.
    @MainActor private func showsWebAPIStatus(_ app: XCUIApplication, _ value: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'webAPIStatus' AND value == %@", value)).firstMatch
            .waitForExistence(timeout: XCUIApplication.timeout)
    }

    /// PBI-208: crossfade starts off, moves by keyboard and is kept after reopening Settings.
    @MainActor func testCrossfadeSliderStartsOffAndKeepsItsLength() throws {
        let app = openSettings()
        tab(app, "Playback").click()
        let crossfade = app.sliders["Crossfade songs"]
        XCTAssertTrue(crossfade.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(crossfade.value as? NSNumber, 0)
        XCTAssertTrue(app.staticTexts["Off"].exists)

        crossfade.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertEqual(crossfade.value as? NSNumber, 6)
        XCTAssertTrue(app.staticTexts["6 s"].exists)
        attachScreenshot(of: app.windows.firstMatch, named: "settings-playback-crossfade")
        try assertAuditPasses(app, "Settings › Playback")

        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        tab(app, "Playback").click()
        XCTAssertTrue(crossfade.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(crossfade.value as? NSNumber, 6)
        XCTAssertTrue(app.staticTexts["6 s"].exists)
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
}
