import XCTest

/// PBI-406: the queue inspector. The scenario queues songs 5 and 6, then songs 7 and 8 follow.
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

        for text in ["Now Playing", "Test Track", "Next in Queue", "Song 6", "Next Up", "Song 7", "Song 8"] {
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

    @MainActor func testDeleteKeyRemovesTheSelectedRow() {
        let app = openQueue()

        app.queue.staticTexts["Song 6"].click()
        app.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(app.queue.staticTexts["Song 6"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.queue.staticTexts["Song 5"].exists)
    }

    @MainActor func testClearQueueEmptiesNextInQueueOnly() {
        let app = openQueue()

        app.queue.buttons["Clear Queue"].click()

        XCTAssertTrue(app.queue.staticTexts["Songs you add to the queue play next."].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.queue.staticTexts["Song 5"].exists)
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
        app.outlines.staticTexts["Albums"].click()
        let album = app.outlines.buttons["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        album.click()
        XCTAssertTrue(app.showsRoute("Test Album"))

        app.buttons["pagePlay"].click()

        XCTAssertTrue(app.queue.staticTexts["Next From: Test Album"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.queue.staticTexts["Song 4"].exists)
        XCTAssertFalse(app.queue.staticTexts["Song 7"].exists)
    }
}

private extension XCUIApplication {
    var queue: XCUIElement {
        outlines["queue"]
    }
}
