import XCTest

/// PBI-401: sidebar destinations and back/forward history; PBI-304: playlist folders.
final class NavigationUITests: XCTestCase {
    @MainActor func testSidebarListsDestinationsAndPlaylists() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        let sidebar = app.outlines.firstMatch
        for item in ["Home", "Search", "Liked Songs", "Albums", "Artists", "Podcasts", "Road Trip"] {
            XCTAssertTrue(sidebar.staticTexts[item].exists, item)
        }
        XCTAssertEqual(app.routeTitle.value as? String, "Home")
    }

    /// PBI-304: folders start collapsed and open to show the playlists inside.
    @MainActor func testPlaylistFolderExpandsToShowItsPlaylists() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(sidebar.staticTexts["Mixes"].exists)
        XCTAssertFalse(sidebar.staticTexts["Morning Mix"].exists)

        sidebar.outlineRows.containing(NSPredicate(format: "value == 'Mixes'")).disclosureTriangles.firstMatch.click()

        XCTAssertTrue(sidebar.staticTexts["Morning Mix"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testSelectingAPlaylistShowsIt() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.outlines.staticTexts["Road Trip"].click()

        XCTAssertTrue(app.showsRoute("Road Trip"))
    }

    @MainActor func testKeyboardBackAndForward() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Liked Songs"].click()
        app.outlines.staticTexts["Albums"].click()
        XCTAssertEqual(app.routeTitle.value as? String, "Albums")

        app.typeKey("[", modifierFlags: .command)
        XCTAssertEqual(app.routeTitle.value as? String, "Liked Songs")

        app.typeKey("]", modifierFlags: .command)
        XCTAssertEqual(app.routeTitle.value as? String, "Albums")
    }

    @MainActor func testToolbarBackAndForward() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let back = app.toolbars.buttons["Back"]
        let forward = app.toolbars.buttons["Forward"]
        XCTAssertFalse(back.isEnabled)

        app.outlines.staticTexts["Artists"].click()
        back.click()
        XCTAssertEqual(app.routeTitle.value as? String, "Home")
        XCTAssertFalse(back.isEnabled)

        forward.click()
        XCTAssertEqual(app.routeTitle.value as? String, "Artists")
        XCTAssertFalse(forward.isEnabled)
    }

    @MainActor func testGoMenuIsDisabledWithoutHistory() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertFalse(app.menuItem("Go", "Back").isEnabled)
    }
}
