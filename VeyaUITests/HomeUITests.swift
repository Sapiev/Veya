import XCTest

/// PBI-307: the Home screen. PBI-105: the scenario's Song 3 is region locked, so it never plays.
final class HomeUITests: XCTestCase {
    private static let sections = ["Made for you", "Artists you follow", "Recently Played"]
    private static let connectWebAPI = "Connect Spotify Web API in Settings to see Recently Played."

    @MainActor private func home(_ scenario: Scenario = .signedIn) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    /// Recently Played is the last shelf, below the fold of the test window.
    @MainActor private func scrollToRecentlyPlayed(_ app: XCUIApplication) {
        let page = app.scrollViews["home"]
        XCTAssertTrue(page.waitForExistence(timeout: XCUIApplication.timeout))
        page.scroll(byDeltaX: 0, deltaY: -2000)
    }

    @MainActor func testShowsEverySectionWithItsItems() {
        let app = home()

        XCTAssertTrue(app.buttons["Song 2, Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        for section in Self.sections {
            XCTAssertTrue(app.staticTexts[section].exists, section)
        }
        for card in ["Song 1, Test Artist", "Test Album, Test Artist", "Road Trip, Songs for the road", "Test Artist, Artist", "Daily Mix 1, Made for you"] {
            XCTAssertTrue(app.buttons[card].exists, card)
        }
        XCTAssertFalse(app.staticTexts[Self.connectWebAPI].exists)
    }

    @MainActor func testGreetsByTimeOfDay() {
        let app = home()
        let greetings = ["Good morning", "Good afternoon", "Good evening", "Good night"]

        let greeting = app.staticTexts["greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(greetings.contains(greeting.value as? String ?? ""))
    }

    /// The design's untitled quick grid sits directly under the greeting.
    @MainActor func testJumpBackInIsUntitledQuickTilesThatOpenTheirPage() {
        let app = home()
        let tile = app.buttons["Road Trip, Songs for the road"]
        XCTAssertTrue(tile.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.staticTexts["Jump Back In"].exists)

        tile.click()

        XCTAssertTrue(app.showsRoute("Road Trip"))
    }

    @MainActor func testMissingScopeHidesRecentSectionsAndAsksToConnectWebAPI() {
        let app = home(.recentlyPlayedNeedsSignIn)

        XCTAssertTrue(app.staticTexts[Self.connectWebAPI].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Daily Mix 1, Made for you"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Made for you"].exists)
        XCTAssertFalse(app.staticTexts["Recently Played"].exists)
        XCTAssertFalse(app.buttons["Song 2, Test Artist"].exists)
        // Jump Back In comes from spclient, which needs no Web API scope.
        XCTAssertTrue(app.buttons["Road Trip, Songs for the road"].exists)
    }

    /// spclient's recent contexts span more than the Web API's last 50 tracks.
    @MainActor func testJumpBackInShowsEveryRecentContext() {
        let app = home()
        let quickTiles = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Jump back in'")).firstMatch

        XCTAssertTrue(quickTiles.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Road Trip, Songs for the road"].waitForExistence(timeout: XCUIApplication.timeout))
        // The scenario's Web API plays name 3 contexts, spclient 5.
        XCTAssertGreaterThan(quickTiles.buttons.count, 3)
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
        let mix = app.buttons["Daily Mix 1, Made for you"]
        XCTAssertTrue(mix.waitForExistence(timeout: XCUIApplication.timeout))

        mix.click()

        XCTAssertTrue(app.showsRoute("Daily Mix 1"))
    }

    @MainActor func testFollowedArtistOpensTheArtistPage() {
        let app = home()
        // The quick grid shows the same artist first; the card is the second match.
        let artist = app.buttons.matching(NSPredicate(format: "label == %@", "Test Artist, Artist")).element(boundBy: 1)
        XCTAssertTrue(artist.waitForExistence(timeout: XCUIApplication.timeout))

        artist.click()

        XCTAssertTrue(app.showsRoute("Test Artist"))
    }

    @MainActor func testClickingARecentTrackPlaysIt() {
        let app = home()
        let song = app.buttons["Song 2, Test Artist"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))
        scrollToRecentlyPlayed(app)

        song.click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).firstMatch.exists)
    }

    @MainActor func testRegionLockedRecentTrackRefusesToPlay() {
        let app = home()
        let locked = app.buttons["Song 3, Test Artist"]
        XCTAssertTrue(locked.waitForExistence(timeout: XCUIApplication.timeout))
        scrollToRecentlyPlayed(app)

        locked.click()

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
    }

    @MainActor func testPlayingRecentTracksLeavesTheRegionLockedOneOut() {
        let app = home()
        XCTAssertTrue(app.buttons["Song 2, Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        app.menuItem("View", "Show Queue").click()
        let queue = app.descendants(matching: .any)["queue"].firstMatch
        scrollToRecentlyPlayed(app)

        app.buttons["Song 2, Test Artist"].click()

        XCTAssertTrue(queue.staticTexts["Song 1"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(queue.staticTexts["Song 3"].exists)
    }
}
