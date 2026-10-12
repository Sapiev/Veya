import XCTest

/// PBI-701: synced, unsynced and missing lyrics in the full Now Playing view.
final class LyricsUITests: XCTestCase {
    @MainActor func testSyncedLinesHighlightTheCurrentLineAndSeekWhenClicked() {
        let app = XCUIApplication.launch(.signedIn)
        openLyrics(in: app)
        let first = app.buttons["Hello from the first line"]
        let second = app.buttons["Here comes the second line"]
        XCTAssertTrue(first.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)

        second.clickCenter()

        XCTAssertTrue(second.waitFor(selected: true))
        XCTAssertFalse(first.isSelected)
        XCTAssertEqual(app.staticTexts["elapsed"].firstMatch.value as? String, "1:00")
    }

    @MainActor func testUnsyncedLyricsShowAsStaticText() {
        let app = playFromQueue("Song 5")
        openLyrics(in: app)

        XCTAssertTrue(app.staticTexts["Words without timing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.buttons["Words without timing"].exists)
    }

    @MainActor func testTrackWithoutLyricsShowsNoLyrics() {
        let app = playFromQueue("Song 6")
        openLyrics(in: app)

        XCTAssertTrue(app.staticTexts["No Lyrics"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["This track has no lyrics."].exists)
    }

    @MainActor private func openLyrics(in app: XCUIApplication) {
        let lyrics = app.buttons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: XCUIApplication.timeout))
        lyrics.click()
    }

    /// Plays an upcoming song from the queue panel; rows in the full Now Playing view don't play.
    @MainActor private func playFromQueue(_ title: String) -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        app.descendants(matching: .any)["Queue"].firstMatch.click()
        let row = app.descendants(matching: .any)["queue"].firstMatch.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: XCUIApplication.timeout))
        row.click()
        return app
    }
}

private extension XCUIElement {
    /// Skips XCUI's scroll-to-visible, which finds no hit point for scroll views in the Now Playing overlay.
    func clickCenter() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func waitFor(selected: Bool) -> Bool {
        let predicate = NSPredicate(format: "isSelected == %@", NSNumber(value: selected))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: XCUIApplication.timeout) == .completed
    }
}
