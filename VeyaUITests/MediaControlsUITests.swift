import XCTest

/// PBI-601: playback, and with it the media keys, outlives the main window.
final class MediaControlsUITests: XCTestCase {
    @MainActor func testClosingTheWindowKeepsPlaying() {
        let app = XCUIApplication.launch(.signedIn)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        play.click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: XCUIApplication.timeout))

        let window = app.menuBars.menuBarItems["Window"]
        window.click()
        window.menuItems["Veya"].click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testQuitStillQuitsWithTheWindowClosed() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: XCUIApplication.timeout))
        app.typeKey("q", modifierFlags: .command)

        XCTAssertTrue(app.wait(for: .notRunning, timeout: XCUIApplication.timeout))
    }
}
