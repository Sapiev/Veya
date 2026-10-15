import XCTest

/// PBI-406: a narrow window keeps the player bar's controls apart and trades the sidebar for the queue.
final class NarrowWindowUITests: XCTestCase {
    @MainActor private func launchNarrow() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn, windowWidth: 900)
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, accuracy: 1)
        return app
    }

    @MainActor private func assertAccessoriesClearTheTransport(_ app: XCUIApplication, _ message: String) {
        let repeatButton = app.buttons["Repeat"].firstMatch
        let lyrics = app.buttons["Lyrics"].firstMatch
        XCTAssertTrue(lyrics.exists, message)
        XCTAssertGreaterThanOrEqual(lyrics.frame.minX, repeatButton.frame.maxX, message)
    }

    @MainActor func testOpeningTheQueueInANarrowWindowHidesTheSidebarUntilItCloses() {
        let app = launchNarrow()
        XCTAssertTrue(app.signedInScreen.exists)

        app.descendants(matching: .any)["Queue"].firstMatch.click()
        XCTAssertTrue(app.queue.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))
        assertAccessoriesClearTheTransport(app, "queue open")
        attachScreenshot(of: app.windows.firstMatch, named: "narrow-queue")

        app.queue.buttons["Close Queue"].click()
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testShowSidebarInANarrowWindowClosesTheQueue() {
        let app = launchNarrow()
        app.descendants(matching: .any)["Queue"].firstMatch.click()
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.menuItem("View", "Show Sidebar").click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.queue.waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testPlayerBarAccessoriesStayClearOfTheTransportWithTheSidebarOpen() {
        let app = launchNarrow()
        XCTAssertTrue(app.signedInScreen.exists)

        assertAccessoriesClearTheTransport(app, "sidebar open")
        XCTAssertTrue(app.buttons["Devices"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Mute"].firstMatch.exists)
        XCTAssertFalse(app.sliders["Volume"].exists, "too narrow for the inline slider")
        attachScreenshot(of: app.windows.firstMatch, named: "narrow-sidebar")
    }

    @MainActor func testHoveringMuteRaisesAnUprightVolumeSlider() {
        let app = launchNarrow()
        let mute = app.buttons["Mute"].firstMatch
        XCTAssertFalse(app.sliders["Volume"].exists)

        mute.hover()
        let slider = app.sliders["Volume"]
        XCTAssertTrue(slider.waitForExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: app.windows.firstMatch, named: "narrow-volume-pop-up")

        let popover = app.popovers.firstMatch
        XCTAssertGreaterThan(popover.frame.height, popover.frame.width, "stands upright")
        XCTAssertLessThanOrEqual(popover.frame.maxY, mute.frame.minY)
        // The slider's frame ignores the rotation but shares its center, so aim along the 96 pt track from there.
        func track(_ fraction: CGFloat) -> XCUICoordinate {
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 48 - 96 * fraction))
        }
        track(0.1).click()
        XCTAssertEqual(slider.normalizedSliderPosition, 0.1, accuracy: 0.05)
        track(0.9).click()
        XCTAssertEqual(slider.normalizedSliderPosition, 0.9, accuracy: 0.05)

        app.buttons["Lyrics"].firstMatch.hover()
        XCTAssertTrue(slider.waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testTheMuteButtonNamesTheVolumeForVoiceOver() {
        let app = launchNarrow()

        XCTAssertNotNil((app.buttons["Mute"].firstMatch.value as? String)?.range(of: #"^\d+%$"#, options: .regularExpression))
    }
}
