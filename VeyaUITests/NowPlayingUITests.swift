import XCTest

/// PBI-402: now-playing bar and expanded Now Playing view.
final class NowPlayingUITests: XCTestCase {
    @MainActor func testBarShowsTheTrackControlsMuteAndPlayAndArtistOpens() {
        let app = XCUIApplication.launch(.signedIn)

        // The bar shows the track and its artist.
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        for control in ["Shuffle", "Previous", "Next", "Repeat", "Queue", "Lyrics", "Mute", "Full-Window Now Playing", "Save to Liked Songs"] {
            XCTAssertTrue(app.descendants(matching: .any)[control].exists, control)
        }
        XCTAssertTrue(app.sliders["Playback Position"].exists)
        XCTAssertTrue(app.sliders["Volume"].exists)
        XCTAssertFalse(app.buttons["Output Device"].exists)

        // Mute silences and restores the volume.
        let mute = app.buttons["Mute"]
        mute.click()
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: XCUIApplication.timeout))
        unmute.click()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: XCUIApplication.timeout))

        // Play and pause follow the player.
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        play.click()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: XCUIApplication.timeout))
        pause.click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))

        // The artist opens the artist page (last: it changes the route).
        app.buttons["Test Artist"].click()
        XCTAssertTrue(app.showsRoute("Test Artist"))
    }

    /// Queue tab and Escape first (the Queue tab is the default), then the Lyrics tab, then the full-window view.
    @MainActor func testExpandedViewQueueEscapeLyricsTabAndFullViewTopEdgeAndKeyReveal() {
        let app = XCUIApplication.launch(.signedIn)
        let expand = app.buttons["Show Now Playing"]
        XCTAssertTrue(expand.waitForExistence(timeout: XCUIApplication.timeout))

        // The expanded view shows the queue and closes with Escape.
        expand.click()
        XCTAssertTrue(app.radioButtons["Queue"].waitForExistence(timeout: XCUIApplication.timeout))
        let queue = app.scrollViews["nowPlayingQueue"]
        for text in ["Now Playing", "Next in Queue", "Song 5", "Next Up", "Song 7"] {
            XCTAssertTrue(queue.staticTexts[text].waitForExistence(timeout: XCUIApplication.timeout), text)
        }
        // Escape works even after the controls fade.
        XCTAssertTrue(app.buttons["Close Now Playing"].waitForNonExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(queue.waitForNonExistence(timeout: XCUIApplication.timeout))

        // The expanded view has a Lyrics tab.
        expand.click()
        let lyrics = app.radioButtons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: XCUIApplication.timeout))
        lyrics.click()
        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Close Now Playing"].click()
        XCTAssertTrue(app.buttons["Hello from the first line"].waitForNonExistence(timeout: XCUIApplication.timeout))

        // The full view covers the window to its top edge.
        let open = app.buttons["Full-Window Now Playing"]
        XCTAssertTrue(open.waitForExistence(timeout: XCUIApplication.timeout))
        open.click()
        let close = app.buttons["Close Now Playing"]
        XCTAssertTrue(close.waitForExistence(timeout: XCUIApplication.timeout))
        // The close button sits 12 pt below the view's top; a title bar gap would push it further down.
        XCTAssertEqual(close.frame.minY - app.windows.firstMatch.frame.minY, 12, accuracy: 1)

        // A key press reveals the faded controls, so keyboard focus never lands on something invisible.
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(close.waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// PBI-208: the bar cross-dissolves to the next track and the old title goes away.
    @MainActor func testNextReplacesTheTrackInTheBar() {
        let app = XCUIApplication.launch(.signedIn)
        let window = app.windows.firstMatch
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: window, named: "track-before")

        app.buttons["Next"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Test Track"].waitForNonExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: window, named: "track-after")

        app.buttons["Full-Window Now Playing"].click()
        XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: window, named: "full-after")
    }

    @MainActor func testQueueAndLyricsHideToCenterThePlayerAndStayHidden() {
        let app = XCUIApplication.launch(.signedIn)
        let open = app.buttons["Full-Window Now Playing"]
        XCTAssertTrue(open.waitForExistence(timeout: XCUIApplication.timeout))
        open.click()
        XCTAssertTrue(app.scrollViews["nowPlayingQueue"].waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Hide Queue and Lyrics"].click()
        XCTAssertTrue(app.buttons["Show Queue and Lyrics"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.scrollViews["nowPlayingQueue"].exists)
        let window = app.windows.firstMatch
        let artwork = app.sliders["Playback Position"].firstMatch
        XCTAssertEqual(artwork.frame.midX, window.frame.midX, accuracy: 2)
        attachScreenshot(of: window, named: "now-playing-panes-hidden")

        app.buttons["Close Now Playing"].click()
        open.click()
        XCTAssertTrue(app.buttons["Show Queue and Lyrics"].waitForExistence(timeout: XCUIApplication.timeout))

        // Asking for lyrics shows them even though the panes were hidden.
        app.buttons["Close Now Playing"].click()
        app.buttons["Lyrics"].click()
        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testLyricsButtonOpensTheLyricsTab() {
        let app = XCUIApplication.launch(.signedIn)
        let lyrics = app.buttons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: XCUIApplication.timeout))

        lyrics.click()

        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// PBI-501: launch shows the account's last track paused where it stopped, ready to resume.
    @MainActor func testLaunchShowsTheRestoredTrackPaused() {
        let app = XCUIApplication.launch(.restoredPlayback)

        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertEqual(app.staticTexts["elapsed"].firstMatch.value as? String, "1:35")
    }

    /// The Queue and Lyrics tabs, the top-right buttons and the window buttons fade while the pointer rests.
    @MainActor func testQueueAndLyricsTabsHideWhileThePointerRests() {
        let app = XCUIApplication.launch(.signedIn)
        let open = app.buttons["Full-Window Now Playing"]
        XCTAssertTrue(open.waitForExistence(timeout: XCUIApplication.timeout))
        open.click()
        let queueTab = app.radioButtons["Queue"]
        XCTAssertTrue(queueTab.waitForExistence(timeout: XCUIApplication.timeout))

        let close = app.buttons["Close Now Playing"]
        let window = app.windows.firstMatch
        XCTAssertTrue(queueTab.waitForNonExistence(timeout: 10))
        XCTAssertFalse(close.exists)
        attachScreenshot(of: window, named: "now-playing-controls-hidden")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).hover()
        XCTAssertTrue(queueTab.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(close.exists)
        attachScreenshot(of: window, named: "now-playing-controls-shown")
        app.radioButtons["Lyrics"].click()
        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// The setting drops the panel behind the queue and lyrics; they stay readable on the artwork.
    @MainActor func testPanesBackgroundCanBeTurnedOff() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["General"].click()
        let toggle = app.toggle("Panel behind queue and lyrics")
        XCTAssertTrue(toggle.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        app.typeKey("w", modifierFlags: .command)

        app.buttons["Full-Window Now Playing"].click()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.scrollViews["nowPlayingQueue"].staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: window, named: "now-playing-queue-no-panel")
        try assertAuditPasses(app, "now-playing-no-panel")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).hover()
        app.radioButtons["Lyrics"].click()
        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: window, named: "now-playing-lyrics-no-panel")
    }

    /// The setting removes the queue and lyrics panel so only the playing artwork is left.
    @MainActor func testPanesCanBeTurnedOff() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["General"].click()
        let toggle = app.toggle("Queue and lyrics panel")
        XCTAssertTrue(toggle.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        app.typeKey("w", modifierFlags: .command)

        app.buttons["Full-Window Now Playing"].click()
        XCTAssertTrue(app.buttons["Show Queue and Lyrics"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.scrollViews["nowPlayingQueue"].exists)
        attachScreenshot(of: app.windows.firstMatch, named: "now-playing-no-panes")
    }

    /// The track list under the full view must not take Delete or Return meant for the view on top.
    @MainActor func testKeysDoNotReachTheHiddenTrackListBeneathTheFullView() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.sidebarItem("Road Trip").click()
        let song = app.trackList.staticTexts["Song 1"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))
        song.click()
        let selected = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: selected
        )], timeout: XCUIApplication.timeout), .completed)

        app.buttons["Full-Window Now Playing"].click()
        let close = app.buttons["Close Now Playing"]
        XCTAssertTrue(close.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(app.buttons["Pause"].exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 1), "Return played the hidden selection")
        attachScreenshot(of: app.windows.firstMatch, named: "now-playing-over-playlist")
        close.click()

        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 2", "Song 5"]), "Delete removed nothing")
        XCTAssertFalse(app.buttons["Pause"].exists, "Return played nothing")
    }
}
