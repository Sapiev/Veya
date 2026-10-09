import XCTest

/// PBI-408: the welcome screen, and no list is ever a blank page.
final class EmptyStatesUITests: XCTestCase {
    @MainActor func testWelcomeSaysUnofficialAndPremiumWithOneSignInButton() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertTrue(app.staticTexts["Veya needs a Spotify Premium account."].exists)
        XCTAssertTrue(app.staticTexts["Veya is an unofficial app, not made or endorsed by Spotify."].exists)
        let signInButtons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sign In"))
        XCTAssertEqual(signInButtons.count, 1)
    }

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
            app.outlines.staticTexts[item].click()
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

    @MainActor func testSavedAlbumsListByNameAndOpenTheirPage() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Albums"].click()

        let album = app.buttons["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        album.click()

        XCTAssertEqual(app.routeTitle.value as? String, "Album")
    }

    @MainActor func testEverySidebarDestinationShowsContent() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        for item in ["Home", "Search", "Liked Songs", "Albums", "Artists", "Podcasts", "Road Trip"] {
            app.outlines.staticTexts[item].click()
            XCTAssertTrue(app.routeTitle.waitForExistence(timeout: XCUIApplication.timeout), item)
            XCTAssertEqual(app.routeTitle.value as? String, item)
        }
    }
}
