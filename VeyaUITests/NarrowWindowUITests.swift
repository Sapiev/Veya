import XCTest

/// PBI-406: a narrow window keeps the player bar's controls apart and trades the sidebar for the queue.
final class NarrowWindowUITests: XCTestCase {
    /// The window's minimum: the narrowest page plus the queue, so opening the queue still leaves a full page.
    static let minWindowWidth = 930

    @MainActor private func launchNarrow(locale: String? = nil) -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn, locale: locale, windowWidth: Self.minWindowWidth)
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.windows.firstMatch.frame.width, CGFloat(Self.minWindowWidth), accuracy: 1)
        return app
    }

    @MainActor private func assertAccessoriesClearTheTransport(_ app: XCUIApplication, _ message: String) {
        let repeatButton = app.buttons["Repeat"].firstMatch
        let lyrics = app.buttons["Lyrics"].firstMatch
        XCTAssertTrue(lyrics.exists, message)
        XCTAssertGreaterThanOrEqual(lyrics.frame.minX, repeatButton.frame.maxX + 8, message)
    }

    @MainActor func testNarrowWindowKeepsAccessoriesClearNamesVolumeSwapsSidebarForQueueAndRaisesVolumeSlider() {
        let app = launchNarrow(locale: "en_US")
        XCTAssertTrue(app.signedInScreen.exists)

        // Sidebar open: accessories stay clear of the transport.
        assertAccessoriesClearTheTransport(app, "sidebar open")
        XCTAssertTrue(app.buttons["Devices"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Mute"].firstMatch.exists)
        XCTAssertFalse(app.sliders["Volume"].exists, "too narrow for the inline slider")
        attachScreenshot(of: app.windows.firstMatch, named: "narrow-sidebar")

        // The mute button names the volume for VoiceOver.
        XCTAssertNotNil((app.buttons["Mute"].firstMatch.value as? String)?.range(of: #"^\d+%$"#, options: .regularExpression))

        // Opening the queue hides the sidebar until it closes.
        app.descendants(matching: .any)["Queue"].firstMatch.click()
        XCTAssertTrue(app.queue.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))
        assertAccessoriesClearTheTransport(app, "queue open")
        attachScreenshot(of: app.windows.firstMatch, named: "narrow-queue")

        app.queue.buttons["Close Queue"].click()
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        // Show Sidebar closes the queue.
        app.descendants(matching: .any)["Queue"].firstMatch.click()
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.menuItem("View", "Show Sidebar").click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.queue.waitForNonExistence(timeout: XCUIApplication.timeout))

        // Hovering mute raises an upright volume slider; last, as clicking it changes the volume.
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
        // Hover first and outwait the pop-up's 300 ms grace period: on a slow runner the pointer can reach the
        // popover late, which closes it and invalidates the slider element mid-click.
        func drag(to fraction: CGFloat) {
            track(fraction).hover()
            XCTAssertFalse(slider.waitForNonExistence(timeout: 0.6), "pop-up stays open under the pointer")
            track(fraction).click()
            let reached = expectation(
                for: NSPredicate(format: "normalizedSliderPosition BETWEEN {%f, %f}", fraction - 0.05, fraction + 0.05),
                evaluatedWith: slider
            )
            wait(for: [reached], timeout: XCUIApplication.timeout)
        }
        drag(to: 0.1)
        drag(to: 0.9)

        app.buttons["Lyrics"].firstMatch.hover()
        XCTAssertTrue(slider.waitForNonExistence(timeout: XCUIApplication.timeout))
    }
}
