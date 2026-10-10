import XCTest

/// PBI-405: the Search screen and its toolbar field. PBI-309: search needs the user's own Web API client ID.
final class SearchUITests: XCTestCase {
    @MainActor private func signedIn() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor private func searchFor(_ query: String, in app: XCUIApplication) {
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchField.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeText(query)
    }

    @MainActor func testCommandFOpensSearchAndFocusesTheFieldFromAnyScreen() {
        let app = signedIn()
        app.outlines.staticTexts["Liked Songs"].click()

        app.typeKey("f", modifierFlags: .command)

        XCTAssertTrue(app.searchField.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.routeTitle.value as? String, "Search")
        app.typeText("abc")
        XCTAssertEqual(app.searchField.value as? String, "abc")
    }

    @MainActor func testCommandLAlsoFocusesTheField() {
        let app = signedIn()

        app.typeKey("l", modifierFlags: .command)

        XCTAssertTrue(app.searchField.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeText("abc")
        XCTAssertEqual(app.searchField.value as? String, "abc")
    }

    @MainActor func testCommandKFocusesTheToolbarFieldAndTypingShowsResults() {
        let app = signedIn()

        app.typeKey("k", modifierFlags: .command)
        app.typeText("test")

        XCTAssertEqual(app.searchField.value as? String, "test")
        XCTAssertTrue(app.searchResults.staticTexts["Top Result"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testTypingInTheToolbarFieldFromAnotherScreenOpensSearch() {
        let app = signedIn()
        app.outlines.staticTexts["Liked Songs"].click()

        app.searchField.click()
        app.typeText("test")

        XCTAssertTrue(app.searchResults.staticTexts["Top Result"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testEscapeClearsTheQueryBackToRecentSearches() {
        let app = signedIn()
        searchFor("test", in: app)
        XCTAssertTrue(app.searchResults.staticTexts["Top Result"].waitForExistence(timeout: XCUIApplication.timeout))

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(app.showsRoute("Search"))
        XCTAssertFalse(app.searchResults.exists)
    }

    @MainActor func testTypingShowsTheTopResultAndASectionPerKind() {
        let app = signedIn()

        searchFor("test", in: app)

        for text in ["Top Result", "Songs", "Artists", "Albums", "Test Artist", "Test Album", "Song 3"] {
            XCTAssertTrue(app.searchResults.staticTexts[text].waitForExistence(timeout: XCUIApplication.timeout), text)
        }
    }

    @MainActor func testTopResultSongPlaysFromItsPlayButton() {
        let app = signedIn()
        searchFor("test", in: app)
        let play = app.searchResults.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))

        play.click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 1")).count >= 2)
    }

    @MainActor func testClickingAnAlbumCardOpensItsPage() {
        let app = signedIn()
        searchFor("test", in: app)
        let album = app.searchResults.staticTexts["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        for _ in 0 ..< 10 where !album.isHittable {
            app.searchResults.scroll(byDeltaX: 0, deltaY: -200)
        }

        album.click()

        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testShowMoreLoadsTheNextPage() {
        let app = signedIn()
        searchFor("test", in: app)
        XCTAssertTrue(app.searchResults.buttons["Show More"].waitForExistence(timeout: XCUIApplication.timeout))

        app.searchResults.buttons["Show More"].click()

        XCTAssertTrue(app.searchResults.staticTexts["Song 4"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testArrowKeysAndReturnPlayTheSelectedTrack() {
        let app = signedIn()
        searchFor("test", in: app)
        XCTAssertTrue(app.searchResults.staticTexts["Song 2"].waitForExistence(timeout: XCUIApplication.timeout))

        // Top Result, Song 1, Song 2.
        for _ in 0 ..< 3 {
            app.typeKey(.downArrow, modifierFlags: [])
        }
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).count >= 2)
    }

    @MainActor func testReturnOnAnArtistOpensItsPage() {
        let app = signedIn()
        searchFor("test", in: app)
        XCTAssertTrue(app.searchResults.staticTexts["Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))

        // Top Result, Song 1, Song 2, Song 3, Test Artist.
        for _ in 0 ..< 5 {
            app.typeKey(.downArrow, modifierFlags: [])
        }
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.showsRoute("Test Artist"))
    }

    @MainActor func testNoResultsAndFailureEachSayWhatHappened() {
        let app = signedIn()
        searchFor("nothing", in: app)
        let noResults = app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", "No Results for")).firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: XCUIApplication.timeout))

        app.searchField.typeKey("a", modifierFlags: .command)
        app.searchField.typeText("fail")

        XCTAssertTrue(app.staticTexts["Couldn't Search"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }

    /// PBI-309
    @MainActor func testRateLimitSaysSo() {
        let app = signedIn()
        searchFor("busy", in: app)

        XCTAssertTrue(app.staticTexts["Search Is Rate Limited"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }

    /// PBI-309
    @MainActor func testNotConnectedAsksToConnectAndOpensAccountSettings() {
        let app = XCUIApplication.launch(.webAPINotConnected)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        searchFor("test", in: app)

        XCTAssertTrue(app.staticTexts["Connect Spotify Web API to Search"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.searchResults.exists)
        app.buttons["Open Settings"].click()

        XCTAssertTrue(app.textFields["Client ID"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'webAPIStatus' AND value == %@", "Not connected"))
            .firstMatch.waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// PBI-309: connecting in Settings brings the pending query's results back.
    @MainActor func testConnectingInSettingsShowsResults() {
        let app = XCUIApplication.launch(.webAPINotConnected)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        searchFor("test", in: app)
        app.buttons["Open Settings"].click()
        let field = app.textFields["Client ID"]
        XCTAssertTrue(field.waitForExistence(timeout: XCUIApplication.timeout))

        field.click()
        field.typeText("0123456789abcdef0123456789abcdef")
        // The "Connect" tab shares the button's name.
        app.scrollViews.buttons["Connect"].click()
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(app.searchResults.staticTexts["Top Result"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testCommittedSearchIsRememberedUntilCleared() {
        let app = signedIn()
        searchFor("test", in: app)
        app.typeKey(.return, modifierFlags: [])
        app.searchField.typeKey("a", modifierFlags: .command)
        app.searchField.typeKey(.delete, modifierFlags: [])

        let recent = app.recentSearches.buttons["test"]
        XCTAssertTrue(recent.waitForExistence(timeout: XCUIApplication.timeout))

        recent.click()
        XCTAssertTrue(app.searchResults.staticTexts["Top Result"].waitForExistence(timeout: XCUIApplication.timeout))

        app.searchField.typeKey("a", modifierFlags: .command)
        app.searchField.typeKey(.delete, modifierFlags: [])
        app.buttons["Clear"].click()
        XCTAssertTrue(app.staticTexts["Search for artists, songs, albums or podcasts."].waitForExistence(timeout: XCUIApplication.timeout))
    }
}

@MainActor
private extension XCUIApplication {
    var searchField: XCUIElement {
        textFields["searchField"]
    }

    var searchResults: XCUIElement {
        descendants(matching: .any)["searchResults"].firstMatch
    }

    var recentSearches: XCUIElement {
        descendants(matching: .any)["recentSearches"].firstMatch
    }
}
