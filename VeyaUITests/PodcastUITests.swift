import XCTest

/// PBI-306: followed shows, the show page and resuming an episode. PBI-105: an
/// unplayable episode cannot be started.
final class PodcastUITests: XCTestCase {
    @MainActor private func openShow() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Podcasts"].click()
        let show = app.outlines.buttons["Test Podcast"]
        XCTAssertTrue(show.waitForExistence(timeout: XCUIApplication.timeout))
        show.click()
        XCTAssertTrue(app.showsRoute("Test Podcast"))
        return app
    }

    @MainActor func testShowPageListsEpisodesWithDateLengthAndProgress() {
        let app = openShow()

        XCTAssertTrue(app.staticTexts["Veya Test Studio"].exists)
        XCTAssertTrue(app.staticTexts["A podcast about testing Veya"].exists)
        for title in ["New Episode", "Halfway Episode", "Finished Episode"] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: XCUIApplication.timeout), title)
        }
        let released = Date(timeIntervalSince1970: 1_759_300_200).formatted(date: .abbreviated, time: .omitted)
        XCTAssertTrue(app.staticTexts[released].exists, released)
        XCTAssertTrue(app.staticTexts["1 hr"].exists)
        XCTAssertTrue(app.staticTexts["35 min left"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Played"].exists)
    }

    @MainActor func testSelectingAnEpisodeShowsItsNotes() {
        let app = openShow()
        let episode = app.staticTexts["Halfway Episode"]
        XCTAssertTrue(episode.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.staticTexts["Notes for Halfway Episode"].exists)

        episode.click()

        XCTAssertTrue(app.staticTexts["Notes for Halfway Episode"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.staticTexts["Notes for New Episode"].exists)
    }

    @MainActor func testResumeStartsTheEpisodeWhereItWasLeft() {
        let app = openShow()
        XCTAssertTrue(app.staticTexts["35 min left"].waitForExistence(timeout: XCUIApplication.timeout))
        app.staticTexts["Halfway Episode"].click()
        let resume = app.buttons["episodePlay"]
        XCTAssertTrue(resume.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(resume.label, "Resume")

        resume.click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.elapsed(beginningWith: "25:0").waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value == %@", "Halfway Episode")).count, 2)
    }

    @MainActor func testPlayedEpisodeStartsFromTheBeginning() {
        let app = openShow()
        XCTAssertTrue(app.staticTexts["Played"].waitForExistence(timeout: XCUIApplication.timeout))
        app.staticTexts["Finished Episode"].click()
        let play = app.buttons["episodePlay"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(play.label, "Play")

        play.click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.elapsed(beginningWith: "0:0").waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testRegionLockedEpisodeCannotBePlayed() {
        let app = openShow()
        let episode = app.staticTexts["Locked Episode"]
        XCTAssertTrue(episode.waitForExistence(timeout: XCUIApplication.timeout))
        episode.click()
        let play = app.buttons["episodePlay"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(play.isEnabled)

        episode.doubleClick()

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
    }
}

private extension XCUIApplication {
    /// The now-playing bar's elapsed time; it keeps advancing while playing.
    func elapsed(beginningWith prefix: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "identifier == 'elapsed' AND value BEGINSWITH %@", prefix)).firstMatch
    }
}
