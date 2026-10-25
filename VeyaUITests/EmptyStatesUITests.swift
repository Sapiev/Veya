import XCTest

/// PBI-408: the welcome screen, and no list is ever a blank page.
final class EmptyStatesUITests: XCTestCase {
    @MainActor func testEmptyLibraryShowsDesignedEmptyStates() {
        let app = XCUIApplication.launch(.emptyLibrary)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.outlines.staticTexts["No Playlists"].waitForExistence(timeout: XCUIApplication.timeout))

        let expected = [
            "Liked Songs": "No Liked Songs",
            "Albums": "No Saved Albums",
            "Artists": "No Followed Artists",
            "Podcasts": "No Followed Podcasts",
        ]
        for (item, state) in expected {
            app.sidebarItem(item).click()
            XCTAssertTrue(app.staticTexts[state].waitForExistence(timeout: XCUIApplication.timeout), state)
        }
    }

    @MainActor func testFailedLibraryShowsErrorWithTryAgain() {
        let app = XCUIApplication.launch(.libraryFails)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.outlines.staticTexts["Couldn't Load Playlists"].waitForExistence(timeout: XCUIApplication.timeout))

        app.outlines.staticTexts["Liked Songs"].click()

        XCTAssertTrue(app.staticTexts["Couldn't Load Liked Songs"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.outlines.buttons["Try Again"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Try Again").count, 2)
    }

    @MainActor func testEverySidebarDestinationShowsContentAndSavedAlbumsOpenTheirPage() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        for item in ["Home", "Search", "Liked Songs", "Albums", "Artists", "Podcasts", "Road Trip"] {
            app.sidebarItem(item).click()
            // Home's only heading is the greeting.
            let shown = item == "Home"
                ? app.staticTexts["greeting"].waitForExistence(timeout: XCUIApplication.timeout)
                : app.showsRoute(item)
            XCTAssertTrue(shown, item)
        }

        // Saved albums list by name and open their page.
        app.sidebarItem("Albums").click()
        let album = app.buttons["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        album.click()

        XCTAssertTrue(app.showsRoute("Test Album"))
    }
}
