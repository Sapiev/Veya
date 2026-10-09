import XCTest

/// PBI-405: the Search screen.
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

    @MainActor func testTypingShowsTheTopResultAndASectionPerKind() {
        let app = signedIn()

        searchFor("test", in: app)

        for text in ["Top Result", "Songs", "Artists", "Albums", "Test Artist", "Test Album", "Song 3"] {
            XCTAssertTrue(app.searchResults.staticTexts[text].waitForExistence(timeout: XCUIApplication.timeout), text)
        }
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

        XCTAssertTrue(app.routeTitle.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.routeTitle.value as? String, "Artist")
    }

    @MainActor func testNoResultsAndFailureEachSayWhatHappened() {
        let app = signedIn()
        searchFor("nothing", in: app)
        XCTAssertTrue(app.staticTexts["No results for “nothing”"].waitForExistence(timeout: XCUIApplication.timeout))

        app.searchField.typeKey("a", modifierFlags: .command)
        app.searchField.typeText("fail")

        XCTAssertTrue(app.staticTexts["Couldn't search. Check your connection and try again."].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Try Again"].exists)
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
