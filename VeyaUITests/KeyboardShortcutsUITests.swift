import XCTest

/// PBI-606: playback shortcuts in the Controls menu, the Help menu's list, and opening Spotify links.
final class KeyboardShortcutsUITests: XCTestCase {
    @MainActor private func signedIn() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [match], timeout: XCUIApplication.timeout) == .completed
    }

    /// The Controls menu lists the playback commands, and their shortcuts work; the Help menu lists them (last: it opens a window).
    @MainActor func testPlaybackShortcutsWorkAndTheMenusListThem() {
        let app = signedIn()

        // Controls menu lists the playback commands (checked first: it shows "Play").
        app.menuBars.menuBarItems["Controls"].click()
        for item in ["Play", "Next", "Previous", "Volume Up", "Volume Down", "Shuffle", "Repeat: Off"] {
            XCTAssertTrue(app.menuBars.menuItems[item].exists, item)
        }
        app.typeKey(.escape, modifierFlags: [])

        // Space toggles playback.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))

        // Command-S toggles shuffle and Command-R cycles repeat.
        let shuffle = app.buttons["Shuffle"].firstMatch
        let repeatButton = app.buttons["Repeat"].firstMatch
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitForValue("On", of: shuffle))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(waitForValue("All", of: repeatButton))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(waitForValue("One", of: repeatButton))

        // Command-arrows change the volume.
        let volume = app.sliders["Volume"]
        let before = volume.normalizedSliderPosition
        app.typeKey(.downArrow, modifierFlags: .command)
        let lowered = expectation(for: NSPredicate(format: "normalizedSliderPosition < %f", before), evaluatedWith: volume)
        wait(for: [lowered], timeout: XCUIApplication.timeout)
        let after = volume.normalizedSliderPosition
        app.typeKey(.upArrow, modifierFlags: .command)
        let raised = expectation(for: NSPredicate(format: "normalizedSliderPosition > %f", after), evaluatedWith: volume)
        wait(for: [raised], timeout: XCUIApplication.timeout)

        // Help menu lists the shortcuts.
        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuItems["Keyboard Shortcuts"].click()
        let window = app.windows["Keyboard Shortcuts"]
        XCTAssertTrue(window.waitForExistence(timeout: XCUIApplication.timeout))
        for action in ["Play or Pause", "Next", "Previous", "Volume Up", "Volume Down", "Shuffle", "Repeat", "Search", "Open Link"] {
            XCTAssertTrue(window.staticTexts[action].exists, action)
        }
    }

    /// Space types into the search field; Open Link and veya:// URLs open pages.
    @MainActor func testSpaceTypesIntoSearchAndSpotifyLinksOpenPages() throws {
        let app = signedIn()

        // Space types into the search field instead of toggling playback.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: XCUIApplication.timeout))
        app.typeText("a b")
        XCTAssertEqual(app.textFields["searchField"].value as? String, "a b")
        XCTAssertTrue(app.buttons["Play"].exists)

        // Open Link opens a pasted Spotify link.
        app.typeKey("o", modifierFlags: .command)
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: XCUIApplication.timeout))
        let open = app.sheets.buttons["Open"]
        field.typeText("not a link")
        XCTAssertFalse(open.isEnabled)
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://open.spotify.com/album/uitest?si=x")
        XCTAssertTrue(open.isEnabled)
        open.click()
        XCTAssertTrue(app.showsRoute("Test Album"))

        // A veya:// URL opens the page.
        try app.open(XCTUnwrap(URL(string: "veya://playlist/uitest")))
        XCTAssertTrue(app.showsRoute("Road Trip"))
    }
}
