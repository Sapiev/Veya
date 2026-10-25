import XCTest

/// PBI-503: while another device plays, the now-playing bar names it and its controls command it.
final class RemoteControlUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication.launch(.remoteControl)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor func testTheBarNamesTheDevicePlayingAndItsControlsCommandTheRemote() {
        let app = launch()

        // The bar names the device playing.
        XCTAssertTrue(app.staticTexts["Playing on Pixel"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Remote Track"].exists)

        // Play, pause and next command the remote.
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))

        play.click()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: XCUIApplication.timeout), "the remote reported playing")

        pause.click()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Next"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Song 2"].waitForExistence(timeout: XCUIApplication.timeout), "the remote skipped")
        XCTAssertTrue(app.staticTexts["Playing on Pixel"].exists)
    }
}
