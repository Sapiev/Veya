import AppKit
import XCTest

/// PBI-403: the shared track list, shown on Liked Songs.
/// PBI-105: the scenario's Song 3 is region locked, so it is dimmed and never plays.
final class TrackListUITests: XCTestCase {
    @MainActor private func likedSongs(_ scenario: Scenario = .signedIn, timeout: TimeInterval = XCUIApplication.timeout) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Liked Songs"].click()
        XCTAssertTrue(app.trackList.staticTexts["Song 1"].waitForExistence(timeout: timeout))
        return app
    }

    @MainActor func testLikedSongsListsEveryTrackWithItsColumns() {
        let app = likedSongs()

        for title in ["Song 1", "Song 5"] {
            XCTAssertTrue(app.trackList.staticTexts[title].exists, title)
        }
        for column in ["#", "Title", "Album", "Date Added", "Duration"] {
            XCTAssertTrue(app.buttons[column].exists, column)
        }
    }

    @MainActor func testDoubleClickPlaysTheRowAndMarksItPlaying() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 2"].doubleClick()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.images["Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).count, 2)
    }

    @MainActor func testReturnPlaysTheSelectedRow() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 4"].click()
        // Return right after the click can beat the selection to the app's key handler.
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 4").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testRegionLockedRowRefusesToPlay() {
        let app = likedSongs()
        let locked = app.trackList.staticTexts["Song 3"]
        XCTAssertTrue(locked.waitForExistence(timeout: XCUIApplication.timeout))

        locked.doubleClick()
        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertFalse(app.trackList.images["Now Playing"].exists)
    }

    @MainActor func testPlayingAListLeavesTheRegionLockedRowOut() {
        let app = likedSongs()
        XCTAssertTrue(app.trackList.staticTexts["Song 3"].waitForExistence(timeout: XCUIApplication.timeout))
        app.menuItem("View", "Show Queue").click()
        let queue = app.outlines["queue"]
        XCTAssertTrue(queue.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))

        app.trackList.staticTexts["Song 2"].doubleClick()

        XCTAssertTrue(queue.staticTexts["Song 4"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(queue.staticTexts["Song 3"].exists)
    }

    @MainActor func testContextMenuOffersTheTrackActions() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 1"].rightClick()

        for item in ["Play Next", "Add to Queue", "Add to Playlist", "Go to Album", "Go to Artist", "Copy Link", "Remove from Liked Songs"] {
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: XCUIApplication.timeout), item)
        }
        XCTAssertFalse(app.menuItems["Add to Playlist"].isEnabled)
    }

    @MainActor func testGoToAlbumOpensTheAlbumPage() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 1"].rightClick()
        app.menuItems["Go to Album"].click()

        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testCopyLinkPutsTheWebLinkOnThePasteboard() {
        let app = likedSongs()
        NSPasteboard.general.clearContents()

        app.trackList.staticTexts["Song 1"].rightClick()
        app.menuItems["Copy Link"].click()

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://open.spotify.com/track/ui-test-1")
    }

    @MainActor func testTitleHeaderSortsDescendingOnSecondClick() {
        let app = likedSongs()
        // Header buttons report as not hittable; click their frame instead.
        let title = app.buttons["Title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        title.click()
        // Two clicks inside the double-click interval arrive as one double-click, which sorts once.
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval + 0.1)
        title.click()

        XCTAssertTrue(app.trackList.outlineRows.firstMatch.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// 10,000 liked songs open as one list. Not a frame-rate check: XCUITest's
    /// accessibility snapshot of a table this size takes tens of seconds per query.
    @MainActor func testTenThousandLikedSongsOpen() {
        let app = likedSongs(.largeLibrary, timeout: 60)

        XCTAssertTrue(app.trackList.staticTexts["Song 2"].exists)
    }
}

private extension XCUIApplication {
    var trackList: XCUIElement {
        outlines["trackList"]
    }
}
