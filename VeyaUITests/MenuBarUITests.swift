import XCTest

/// PBI-602: the menu bar mini-player controls playback with the window closed.
final class MenuBarUITests: XCTestCase {
    @MainActor func testMiniPlayerControlsPlaybackWithTheWindowClosedAndTheArtworkBringsTheWindowBack() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.openMiniPlayer()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        play.click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Test Track"].exists)
        XCTAssertTrue(app.buttons["Save to Liked Songs"].exists || app.buttons["Remove from Liked Songs"].exists)
        XCTAssertTrue(app.sliders["Playback Position"].exists)
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.buttons["Open Veya"].click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testMenuBarOnlyStillReopensTheWindow() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.openGeneralSettings()
        let menuBarOnly = app.toggle("Keep running in menu bar only")
        XCTAssertTrue(menuBarOnly.waitForExistence(timeout: XCUIApplication.timeout))
        menuBarOnly.click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.openMiniPlayer()
        app.buttons["Play"].click()
        app.buttons["Open Veya"].click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testSongTitleShowsInTheMenuBarAndHidingTheMenuBarItemDisablesMenuBarOnly() {
        let app = XCUIApplication.launch(.signedIn)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        play.click()
        app.openGeneralSettings()
        let showsTitle = app.toggle("Show song title in menu bar")
        XCTAssertTrue(showsTitle.waitForExistence(timeout: XCUIApplication.timeout))

        showsTitle.click()

        XCTAssertTrue(app.statusItems["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))

        let shown = app.toggle("Show mini player in menu bar")
        XCTAssertTrue(shown.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.menuBarItem.exists)

        shown.click()

        XCTAssertTrue(app.menuBarItem.waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.toggle("Keep running in menu bar only").isEnabled)
        XCTAssertFalse(app.toggle("Show song title in menu bar").isEnabled)
    }
}

@MainActor
private extension XCUIApplication {
    /// Veya's one status item, whichever label it shows.
    var menuBarItem: XCUIElement {
        statusItems.firstMatch
    }

    func openGeneralSettings() {
        typeKey(",", modifierFlags: .command)
        let general = toolbars.buttons["General"]
        XCTAssertTrue(general.waitForExistence(timeout: XCUIApplication.timeout))
        general.click()
    }

    /// On a crowded menu bar the item starts hidden: the first click only reveals it.
    func openMiniPlayer() {
        for _ in 0 ..< 2 where !buttons["Play"].exists {
            menuBarItem.click()
            _ = buttons["Play"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(buttons["Play"].exists)
    }
}
