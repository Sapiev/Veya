import XCTest

/// PBI-404: album, artist and playlist pages; PBI-304: playlist follower count;
/// PBI-105: a region-locked top track does not play. The full-bleed artist header runs under the top bar.
final class DetailPagesUITests: XCTestCase {
    @MainActor private func open(_ sidebarItem: String, then item: String? = nil, title: String) -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.sidebarItem(sidebarItem).click()
        if let item {
            let button = app.savedItems.buttons[item]
            XCTAssertTrue(button.waitForExistence(timeout: XCUIApplication.timeout), item)
            button.click()
        }
        XCTAssertTrue(app.showsRoute(title), title)
        return app
    }

    @MainActor func testAlbumShowsHeaderTracksAndCopyrightWithoutAlbumColumnPlaysAndHeartTogglesSave() {
        let app = open("Albums", then: "Test Album", title: "Test Album")

        XCTAssertTrue(app.staticTexts["2024 · 3 songs, 6 min"].waitForExistence(timeout: XCUIApplication.timeout))
        for title in ["Song 1", "Song 2", "Song 4"] {
            XCTAssertTrue(app.trackList.staticTexts[title].exists, title)
        }
        XCTAssertFalse(app.trackList.staticTexts["Song 3"].exists)
        XCTAssertTrue(app.staticTexts["© 2024 Veya Test Records"].exists)

        // Album pages drop the album column: every row is on this album.
        XCTAssertTrue(app.trackList.staticTexts["Song 1"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Title"].exists)
        XCTAssertFalse(app.buttons["Album"].exists)

        app.buttons["pagePlay"].click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.images["Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 1")).count, 2)

        let remove = app.buttons["Remove from Library"]
        XCTAssertTrue(remove.waitForExistence(timeout: XCUIApplication.timeout))
        remove.click()

        XCTAssertTrue(app.buttons["Save to Library"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testArtistShowsSectionsFollowTogglesLockedTrackRefusesAndTopTrackPlaysThenDiscographyOpensTheAlbum() {
        let app = open("Artists", then: "Test Artist", title: "Test Artist")

        XCTAssertTrue(app.buttons["1, Song 2, 2:02"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Test Album, 2024"].exists)
        app.artistPage.scroll(byDeltaX: 0, deltaY: -1000)
        for text in ["Popular", "Albums", "Singles and EPs", "Fans Also Like"] {
            XCTAssertTrue(app.staticTexts[text].exists, text)
        }
        XCTAssertTrue(app.buttons["Test Single, 2025"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Related Artist"].exists)
        XCTAssertFalse(app.staticTexts["Compilations"].exists)

        app.artistPage.scroll(byDeltaX: 0, deltaY: 1000)
        let following = app.buttons["Following"]
        XCTAssertTrue(following.waitForExistence(timeout: XCUIApplication.timeout))
        following.click()
        XCTAssertTrue(app.buttons["Follow"].waitForExistence(timeout: XCUIApplication.timeout))

        // PBI-105: a region-locked top track does not play.
        let locked = app.buttons["3, Song 3, 2:03"]
        XCTAssertTrue(locked.waitForExistence(timeout: XCUIApplication.timeout))
        locked.click()

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Play"].exists)

        let topTrack = app.buttons["2, Song 1, 2:01"]
        XCTAssertTrue(topTrack.waitForExistence(timeout: XCUIApplication.timeout))
        topTrack.click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))

        // The card sits below the fold of the test window; macOS doesn't scroll to it.
        app.artistPage.scroll(byDeltaX: 0, deltaY: -300)
        app.buttons["Test Album, 2024"].click()
        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testFullBleedArtistHeaderStartsAtTheWindowTop() {
        let app = open("Artists", then: "Test Artist", title: "Test Artist")
        app.artistPage.scroll(byDeltaX: 0, deltaY: -1000)
        let related = app.buttons["Related Artist"]
        XCTAssertTrue(related.waitForExistence(timeout: XCUIApplication.timeout))
        related.click()
        XCTAssertTrue(app.showsRoute("Related Artist"))

        let window = app.windows.firstMatch.frame
        XCTAssertEqual(app.artistPage.frame.minY, window.minY, accuracy: 1)
    }

    @MainActor func testPlaylistShowsHeaderReturnInFilterDoesNotPlayAndFilterNarrowsRows() {
        let app = open("Road Trip", title: "Road Trip")
        XCTAssertTrue(app.staticTexts["Songs for the road"].exists)
        XCTAssertTrue(app.buttons["By UI Test · 3 songs"].exists)
        XCTAssertTrue(app.staticTexts["\(1234.formatted()) followers"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))

        // Return in the filter field must not play the table's selection.
        app.trackList.staticTexts["Song 5"].click()
        let filter = app.textFields["Filter"]
        filter.click()
        filter.typeText("Song\r")

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.trackList.images["Now Playing"].exists)

        filter.typeKey("a", modifierFlags: .command)
        filter.typeText("Song 2")

        XCTAssertTrue(app.trackList.staticTexts["Song 2"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.trackList.staticTexts["Song 1"].exists)
        XCTAssertFalse(app.trackList.staticTexts["Song 5"].exists)
    }
}

private extension XCUIApplication {
    var artistPage: XCUIElement {
        scrollViews.containing(.staticText, identifier: "routeTitle").firstMatch
    }
}
