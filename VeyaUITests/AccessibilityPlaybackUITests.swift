import XCTest

/// PBI-801: playback screens read well to VoiceOver, work from the keyboard and pass the accessibility audit.
final class AccessibilityPlaybackUITests: XCTestCase {
    @MainActor private func likedSongs() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Liked Songs"].click()
        XCTAssertTrue(app.trackList.staticTexts["Song 1"].waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor private func trackRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.trackList.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
    }

    @MainActor func testTrackRowReadsTitleArtistDurationAndPlayingState() {
        let app = likedSongs()
        let row = trackRow(app, "Song 2")
        XCTAssertEqual(row.label, "Song 2, Test Artist, 2 minutes, 2 seconds")

        app.trackList.staticTexts["Song 2"].doubleClick()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(row.label, "Song 2, Test Artist, 2 minutes, 2 seconds, Now playing")

        app.buttons["Pause"].click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(row.label, "Song 2, Test Artist, 2 minutes, 2 seconds, Paused")
    }

    @MainActor func testArrowAndReturnPlayTheNextRow() {
        let app = likedSongs()
        let list = app.trackList
        list.staticTexts["Song 1"].click()
        let first = list.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)

        app.typeKey(.downArrow, modifierFlags: [])
        let second = list.outlineRows.containing(.staticText, identifier: "Song 2").firstMatch
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: second)
        waitForExpectations(timeout: XCUIApplication.timeout)
        app.typeKey(.return, modifierFlags: [])

        let playing = NSPredicate(format: "label ENDSWITH 'Now playing'")
        expectation(for: playing, evaluatedWith: trackRow(app, "Song 2"))
        waitForExpectations(timeout: XCUIApplication.timeout)
    }

    @MainActor func testDevicesPopoverMovesByArrowsPicksWithReturnAndClosesWithEscape() {
        let app = XCUIApplication.launch(.connectDevices)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Devices"].firstMatch.click()
        let speaker = app.popovers.buttons["Kitchen Speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout: XCUIApplication.timeout))

        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: app.popovers.buttons["Pixel"])
        waitForExpectations(timeout: XCUIApplication.timeout)
        // Focus opens on the active device, Pixel, listed right under Kitchen Speaker.
        app.typeKey(.upArrow, modifierFlags: [])
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: speaker)
        waitForExpectations(timeout: XCUIApplication.timeout)
        app.typeKey(.return, modifierFlags: [])
        expectation(for: NSPredicate(format: "value == 'Playing, volume 50%'"), evaluatedWith: speaker)
        waitForExpectations(timeout: XCUIApplication.timeout)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(speaker.waitForNonExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testLyricsMoveByArrowsAndSeekWithReturn() {
        let app = XCUIApplication.launch(.signedIn)
        let lyrics = app.buttons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: XCUIApplication.timeout))
        lyrics.click()
        let first = app.buttons["Hello from the first line"]
        let second = app.buttons["Here comes the second line"]
        XCTAssertTrue(second.waitForExistence(timeout: XCUIApplication.timeout))
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: second)
        waitForExpectations(timeout: XCUIApplication.timeout)

        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: first)
        waitForExpectations(timeout: XCUIApplication.timeout)
    }

    @MainActor func testNowPlayingViewHidesTheShellBeneathIt() {
        let app = XCUIApplication.launch(.signedIn)
        let open = app.buttons["Full-Window Now Playing"]
        XCTAssertTrue(open.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.outlines.staticTexts["Liked Songs"].exists)

        open.click()

        XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.outlines.staticTexts["Liked Songs"].exists)
    }

    @MainActor func testTrackListPassesTheAudit() throws {
        let app = likedSongs()
        try assertAuditPasses(app, "Track list")
    }

    @MainActor func testNowPlayingViewPassesTheAudit() throws {
        let app = XCUIApplication.launch(.signedIn)
        let open = app.buttons["Full-Window Now Playing"]
        XCTAssertTrue(open.waitForExistence(timeout: XCUIApplication.timeout))
        open.click()
        XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Now Playing")
    }

    @MainActor func testLyricsPassTheAudit() throws {
        let app = XCUIApplication.launch(.signedIn)
        let lyrics = app.buttons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: XCUIApplication.timeout))
        lyrics.click()
        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Lyrics")
    }

    @MainActor func testQueuePassesTheAudit() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        app.descendants(matching: .any)["Queue"].firstMatch.click()
        let queue = app.descendants(matching: .any)["queue"].firstMatch
        XCTAssertTrue(queue.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Queue")
    }

    @MainActor func testDevicesPopoverPassesTheAudit() throws {
        let app = XCUIApplication.launch(.connectDevices)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Devices"].firstMatch.click()
        XCTAssertTrue(app.popovers.buttons["Pixel"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Devices popover")
    }
}

private extension XCUIApplication {
    var trackList: XCUIElement {
        outlines["trackList"]
    }
}
