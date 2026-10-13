import XCTest

/// PBI-405: the Search screen and its toolbar field, rebuilt to the design mockup. PBI-309: search needs the user's own Web API client ID.
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
        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testTypingInTheToolbarFieldFromAnotherScreenOpensSearch() {
        let app = signedIn()
        app.outlines.staticTexts["Liked Songs"].click()

        app.searchField.click()
        app.typeText("test")

        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testEscapeClearsTheQueryBackToRecentSearches() {
        let app = signedIn()
        searchFor("test", in: app)
        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(app.showsRoute("Search"))
        XCTAssertTrue(app.searchResults.waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testTypingShowsTheTopResultAndASectionPerKind() {
        let app = signedIn()

        searchFor("test", in: app)

        for text in ["Top result", "Songs", "Artists", "Albums", "Test Artist", "Test Album", "Song 3"] {
            XCTAssertTrue(app.searchResults.staticTexts[text].waitForExistence(timeout: XCUIApplication.timeout), text)
        }
    }

    @MainActor func testMatchingArtistIsTheTopResultAndOpensItsPage() {
        let app = signedIn()
        searchFor("test", in: app)
        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.searchResults.staticTexts["Artist"].exists)

        // The top result's name, above the Artists rail's copy.
        app.searchResults.staticTexts.matching(NSPredicate(format: "value == %@", "Test Artist")).firstMatch.click()

        XCTAssertTrue(app.showsRoute("Test Artist"))
    }

    @MainActor func testDoubleClickingASongRowPlaysIt() {
        let app = signedIn()
        searchFor("test", in: app)
        let song = app.searchResults.staticTexts["Song 2"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))

        song.doubleClick()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).count >= 2)
    }

    @MainActor func testClickingASongRowSelectsItWithoutPlaying() {
        let app = signedIn()
        searchFor("test", in: app)
        let row = app.searchResults.buttons.containing(NSPredicate(format: "value == %@", "Song 2")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: XCUIApplication.timeout))

        row.staticTexts["Song 2"].click()

        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)
        XCTAssertFalse(app.buttons["Pause"].exists)
    }

    @MainActor func testFilterChipsShowCountsAndNarrowTheResults() {
        let app = signedIn()
        searchFor("test", in: app)
        let songs = app.searchResults.buttons["Songs, 4 results"]
        XCTAssertTrue(songs.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.searchResults.buttons["Artists, 1 result"].isEnabled)
        XCTAssertFalse(app.searchResults.buttons["Playlists, 0 results"].isEnabled)

        songs.click()

        XCTAssertTrue(app.searchResults.staticTexts["Song 3"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.searchResults.staticTexts["Test Album"].waitForNonExistence(timeout: XCUIApplication.timeout))

        app.searchResults.buttons["All"].click()
        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testClickingAnAlbumCardOpensItsPage() {
        let app = signedIn()
        searchFor("test", in: app)
        let album = app.searchResults.staticTexts["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        // isHittable holds under the player bar too, so scroll until the card is inside the visible results.
        // Scroll near the top, over Songs: the center can land on a horizontal card rail, which keeps vertical scrolls.
        for _ in 0 ..< 10 where !app.searchResults.frame.contains(album.frame) {
            app.searchResults.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.15)).scroll(byDeltaX: 0, deltaY: -200)
        }

        album.click()

        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testShowMoreLoadsTheNextPage() {
        let app = signedIn()
        searchFor("test", in: app)
        let songs = app.searchResults.buttons["Songs, 4 results"]
        XCTAssertTrue(songs.waitForExistence(timeout: XCUIApplication.timeout))
        songs.click()
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
        XCTAssertTrue(app.noResultsTitle(for: "nothing").waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Check the spelling, or try one of these:"].exists)

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
        XCTAssertTrue(app.searchResults.waitForNonExistence(timeout: XCUIApplication.timeout))
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

        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))
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
        XCTAssertTrue(app.searchResults.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))

        app.searchField.typeKey("a", modifierFlags: .command)
        app.searchField.typeKey(.delete, modifierFlags: [])
        app.buttons["Clear all"].click()
        XCTAssertTrue(app.staticTexts["Browse all"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.recentSearches.waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testRemovingOneRecentSearchKeepsTheOthers() {
        let app = signedIn()
        for query in ["first", "second"] {
            searchFor(query, in: app)
            app.typeKey(.return, modifierFlags: [])
            app.buttons["Clear Search"].click()
        }
        XCTAssertTrue(app.recentSearches.buttons["second"].waitForExistence(timeout: XCUIApplication.timeout))

        app.recentSearches.buttons["Remove second from recent searches"].click()

        XCTAssertTrue(app.recentSearches.buttons["first"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.recentSearches.buttons["second"].waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testNoResultsSuggestionSearchesForIt() {
        let app = signedIn()
        searchFor("hj", in: app)
        let suggestion = app.buttons["Radiohead"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: XCUIApplication.timeout))

        suggestion.click()

        XCTAssertEqual(app.searchField.value as? String, "Radiohead")
        XCTAssertTrue(app.noResultsTitle(for: "Radiohead").waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testIdlePageBrowsesGenresAndTheClearButtonReturnsToIt() {
        let app = signedIn()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Browse all"].waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Hip-hop"].click()

        XCTAssertEqual(app.searchField.value as? String, "Hip-hop")
        app.buttons["Clear Search"].click()
        XCTAssertEqual(app.routeTitle.value as? String, "Search")
        XCTAssertTrue(app.staticTexts["Browse all"].exists)
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

    /// A heading: its text is the label, not the value.
    func noResultsTitle(for query: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", "No results for “\(query)”")).firstMatch
    }

    var recentSearches: XCUIElement {
        descendants(matching: .any)["recentSearches"].firstMatch
    }
}
