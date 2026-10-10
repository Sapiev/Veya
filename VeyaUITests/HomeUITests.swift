import XCTest

/// PBI-307: the Home screen. PBI-105: the scenario's Song 3 is region locked, so it never plays.
final class HomeUITests: XCTestCase {
    private static let sections = ["Recently Played", "Jump Back In", "Made for You"]
    private static let signInAgain = "Sign out and sign in again to see Recently Played and Jump Back In."

    @MainActor private func home(_ scenario: Scenario = .signedIn) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.showsRoute("Home"))
        return app
    }

    @MainActor func testShowsEverySectionWithItsItems() {
        let app = home()

        XCTAssertTrue(app.buttons["Song 2, Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        for section in Self.sections {
            XCTAssertTrue(app.staticTexts[section].exists, section)
        }
        for card in ["Song 1, Test Artist", "Test Album, Test Artist", "Road Trip", "Test Artist, Artist", "Daily Mix 1"] {
            XCTAssertTrue(app.buttons[card].exists, card)
        }
        XCTAssertFalse(app.staticTexts[Self.signInAgain].exists)
    }

    @MainActor func testGreetsByTimeOfDay() {
        let app = home()
        let greetings = ["Good morning", "Good afternoon", "Good evening", "Good night"]

        let greeting = app.staticTexts["greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(greetings.contains(greeting.value as? String ?? ""))
    }

    @MainActor func testJumpBackInIsQuickTilesThatOpenTheirPage() {
        let app = home()
        let tile = app.buttons["Road Trip"]
        XCTAssertTrue(tile.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Jump Back In"].exists)

        tile.click()

        XCTAssertTrue(app.showsRoute("Road Trip"))
    }

    @MainActor func testMissingScopeHidesRecentSectionsAndAsksToSignInAgain() {
        let app = home(.recentlyPlayedNeedsSignIn)

        XCTAssertTrue(app.staticTexts[Self.signInAgain].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Daily Mix 1"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Made for You"].exists)
        XCTAssertFalse(app.staticTexts["Recently Played"].exists)
        XCTAssertFalse(app.staticTexts["Jump Back In"].exists)
        XCTAssertFalse(app.buttons["Song 2, Test Artist"].exists)
    }

    @MainActor func testNothingToShowIsADesignedEmptyState() {
        let app = home(.emptyLibrary)

        XCTAssertTrue(app.staticTexts["Nothing Here Yet"].waitForExistence(timeout: XCUIApplication.timeout))
        for section in Self.sections {
            XCTAssertFalse(app.staticTexts[section].exists, section)
        }
    }

    @MainActor func testEverySectionFailingShowsErrorWithTryAgain() {
        let app = home(.libraryFails)

        XCTAssertTrue(app.staticTexts["Couldn't Load Home"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.buttons.matching(identifier: "Try Again").count, 2)
    }

    @MainActor func testClickingAnAlbumOpensItsPage() {
        let app = home()
        let album = app.buttons["Test Album, Test Artist"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))

        album.click()

        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testClickingAMadeForYouPlaylistOpensItsPage() {
        let app = home()
        let mix = app.buttons["Daily Mix 1"]
        XCTAssertTrue(mix.waitForExistence(timeout: XCUIApplication.timeout))

        mix.click()

        XCTAssertTrue(app.showsRoute("Daily Mix 1"))
    }

    @MainActor func testClickingARecentTrackPlaysIt() {
        let app = home()
        let song = app.buttons["Song 2, Test Artist"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))

        song.click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).firstMatch.exists)
    }

    @MainActor func testRegionLockedRecentTrackRefusesToPlay() {
        let app = home()
        let locked = app.buttons["Song 3, Test Artist"]
        XCTAssertTrue(locked.waitForExistence(timeout: XCUIApplication.timeout))

        locked.click()

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
    }

    @MainActor func testPlayingRecentTracksLeavesTheRegionLockedOneOut() {
        let app = home()
        XCTAssertTrue(app.buttons["Song 2, Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        app.menuItem("View", "Show Queue").click()
        let queue = app.outlines["queue"]

        app.buttons["Song 2, Test Artist"].click()

        XCTAssertTrue(queue.staticTexts["Song 1"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(queue.staticTexts["Song 3"].exists)
    }
}
