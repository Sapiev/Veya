import XCTest

/// PBI-406: the floating queue panel. The scenario queues songs 5 and 6, then songs 7 and 8 follow.
final class QueueUITests: XCTestCase {
    @MainActor private func openQueue() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        app.descendants(matching: .any)["Queue"].firstMatch.click()
        XCTAssertTrue(app.queue.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor func testQueueButtonShowsNowPlayingQueuedAndUpcomingSongs() {
        let app = openQueue()

        for text in ["Queue", "Now playing", "Test Track", "Next in queue", "Song 6", "Next up", "Song 7", "Song 8"] {
            XCTAssertTrue(app.queue.staticTexts[text].exists, text)
        }
    }

    @MainActor func testRemoveFromQueueDeletesTheRow() {
        let app = openQueue()

        app.queue.staticTexts["Song 5"].rightClick()
        app.menuItems["Remove from Queue"].click()

        XCTAssertTrue(app.queue.staticTexts["Song 5"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.queue.staticTexts["Song 6"].exists)
    }

    @MainActor func testClickingAnUpcomingRowPlaysItAndSkipsTheRowsBeforeIt() {
        let app = openQueue()

        app.queue.staticTexts["Song 7"].click()

        XCTAssertTrue(app.queue.staticTexts["Song 5"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.queue.staticTexts["Next in queue"].exists)
        XCTAssertTrue(app.queue.staticTexts["Song 7"].exists)
        XCTAssertTrue(app.queue.staticTexts["Song 8"].exists)
    }

    @MainActor func testTheCloseButtonAndTheTopBarToggleShareOneState() {
        let app = openQueue()

        app.queue.buttons["Close Queue"].click()
        XCTAssertTrue(app.queue.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.descendants(matching: .any)["Queue"].firstMatch.click()
        XCTAssertTrue(app.queue.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testClearQueueEmptiesNextInQueueOnly() {
        let app = openQueue()

        app.queue.buttons["Clear queue"].click()

        XCTAssertTrue(app.queue.staticTexts["Song 5"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.queue.staticTexts["Next in queue"].exists)
        XCTAssertTrue(app.queue.staticTexts["Song 7"].exists)
    }

    @MainActor func testAddToQueueFromTheTrackListAppearsInTheQueue() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.menuItem("View", "Show Queue").click()
        XCTAssertTrue(app.queue.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Liked Songs"].click()
        let row = app.outlines["trackList"].staticTexts["Song 2"]
        XCTAssertTrue(row.waitForExistence(timeout: XCUIApplication.timeout))

        row.rightClick()
        app.menuItems["Add to Queue"].click()

        XCTAssertTrue(app.queue.staticTexts["Song 2"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testPlayingAnAlbumShowsWhatFollowsFromIt() {
        let app = openQueue()
        app.sidebarItem("Albums").click()
        let album = app.savedItems.buttons["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        album.click()
        XCTAssertTrue(app.showsRoute("Test Album"))

        app.buttons["pagePlay"].click()

        XCTAssertTrue(app.queue.staticTexts["Next from: Test Album"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.queue.staticTexts["Song 4"].exists)
        XCTAssertFalse(app.queue.staticTexts["Song 7"].exists)
    }
}

private extension XCUIApplication {
    var queue: XCUIElement {
        descendants(matching: .any)["queue"].firstMatch
    }
}
