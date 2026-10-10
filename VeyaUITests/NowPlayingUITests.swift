import XCTest

/// PBI-402: now-playing bar and expanded Now Playing view.
final class NowPlayingUITests: XCTestCase {
    @MainActor func testBarShowsTheTrackAndItsArtist() {
        let app = XCUIApplication.launch(.signedIn)

        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        for control in ["Shuffle", "Previous", "Next", "Repeat", "Queue", "Output Device", "Save to Liked Songs"] {
            XCTAssertTrue(app.descendants(matching: .any)[control].exists, control)
        }
        XCTAssertTrue(app.sliders["Playback Position"].exists)
        XCTAssertTrue(app.sliders["Volume"].exists)
    }

    @MainActor func testPlayAndPauseFollowThePlayer() {
        let app = XCUIApplication.launch(.signedIn)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))

        play.click()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: XCUIApplication.timeout))

        pause.click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testArtistOpensTheArtistPage() {
        let app = XCUIApplication.launch(.signedIn)
        let artist = app.buttons["Test Artist"]
        XCTAssertTrue(artist.waitForExistence(timeout: XCUIApplication.timeout))

        artist.click()

        XCTAssertTrue(app.showsRoute("Test Artist"))
    }

    @MainActor func testExpandedViewHasALyricsTab() {
        let app = XCUIApplication.launch(.signedIn)
        let expand = app.buttons["Show Now Playing"]
        XCTAssertTrue(expand.waitForExistence(timeout: XCUIApplication.timeout))

        expand.click()
        let lyrics = app.radioButtons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: XCUIApplication.timeout))
        lyrics.click()

        XCTAssertTrue(app.staticTexts["Lyrics aren't available yet."].waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Close Now Playing"].click()
        XCTAssertTrue(app.staticTexts["Lyrics aren't available yet."].waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testExpandedViewShowsTheQueueAndClosesWithEscape() {
        let app = XCUIApplication.launch(.signedIn)
        let expand = app.buttons["Show Now Playing"]
        XCTAssertTrue(expand.waitForExistence(timeout: XCUIApplication.timeout))

        expand.click()
        XCTAssertTrue(app.radioButtons["Queue"].waitForExistence(timeout: XCUIApplication.timeout))
        let queue = app.scrollViews["nowPlayingQueue"]
        for text in ["Now Playing", "Next in Queue", "Song 5", "Next Up", "Song 7"] {
            XCTAssertTrue(queue.staticTexts[text].waitForExistence(timeout: XCUIApplication.timeout), text)
        }
        XCTAssertTrue(app.buttons["Close Now Playing"].exists)

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(queue.waitForNonExistence(timeout: XCUIApplication.timeout))
    }
}
