import AppKit
import XCTest

/// PBI-403: the shared track list, shown on Liked Songs.
/// PBI-105: the scenario's Song 3 is region locked, so it is dimmed and never plays.
final class TrackListUITests: XCTestCase {
    @MainActor private func likedSongs(_ scenario: Scenario = .signedIn, timeout: TimeInterval = XCUIApplication.timeout) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Liked Songs"].click()
        XCTAssertTrue(app.trackList.staticTexts["Song 1"].waitForExistence(timeout: timeout))
        return app
    }

    @MainActor func testLikedSongsListsEveryTrackWithItsColumns() {
        let app = likedSongs()

        for title in ["Song 1", "Song 5"] {
            XCTAssertTrue(app.trackList.staticTexts[title].exists, title)
        }
        for column in ["#", "Title", "Album", "Date Added", "Duration"] {
            XCTAssertTrue(app.buttons[column].exists, column)
        }
    }

    @MainActor func testDoubleClickPlaysTheRowAndMarksItPlaying() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 2"].doubleClick()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.images["Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).count, 2)
    }

    @MainActor func testReturnPlaysTheSelectedRow() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 4"].click()
        // Return right after the click can beat the selection to the app's key handler.
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 4").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// The focused selection is the palette tint (Veya's red by default), never the system blue.
    @MainActor func testSelectionUsesTheAccentNotSystemBlue() throws {
        let app = likedSongs()
        let title = app.trackList.staticTexts["Song 2"]
        title.click()
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 2").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)

        // Just left of the title, between the artwork and the text: only the selection is drawn there.
        let color = try screenColors(y: title.frame.midY, x: [title.frame.minX - 6])[0]
        XCTAssertGreaterThan(color.redComponent, color.blueComponent + 0.2, "\(color)")
    }

    /// The right-click outline is the palette tint too, never the system blue.
    @MainActor func testRightClickOutlineUsesTheAccentNotSystemBlue() throws {
        let app = likedSongs()
        let title = app.trackList.staticTexts["Song 4"]
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 4").firstMatch
        title.rightClick()
        XCTAssertTrue(app.menuItems["Play Next"].waitForExistence(timeout: XCUIApplication.timeout))

        // Across the row's leading edge, which the outline crosses and the menu never covers.
        let colors = try screenColors(y: title.frame.midY, x: Array(stride(from: row.frame.minX, to: row.frame.minX + 30, by: 0.5)))
        XCTAssertFalse(colors.contains { $0.blueComponent > $0.redComponent + 0.2 }, "\(colors)")
        XCTAssertTrue(colors.contains { $0.redComponent > $0.blueComponent + 0.3 }, "\(colors)")
    }

    /// Screen colors along a row of screen points.
    @MainActor private func screenColors(y: CGFloat, x: [CGFloat]) throws -> [NSColor] {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCUIScreen.main.screenshot().pngRepresentation))
        let scale = CGFloat(rep.pixelsWide) / (try XCTUnwrap(NSScreen.screens.first)).frame.width
        return try x.map { try XCTUnwrap(rep.colorAt(x: Int($0 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)) }
    }

    @MainActor func testRegionLockedRowRefusesToPlay() {
        let app = likedSongs()
        let locked = app.trackList.staticTexts["Song 3"]
        XCTAssertTrue(locked.waitForExistence(timeout: XCUIApplication.timeout))

        locked.doubleClick()
        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertFalse(app.trackList.images["Now Playing"].exists)
    }

    @MainActor func testPlayingAListLeavesTheRegionLockedRowOut() {
        let app = likedSongs()
        XCTAssertTrue(app.trackList.staticTexts["Song 3"].waitForExistence(timeout: XCUIApplication.timeout))
        app.menuItem("View", "Show Queue").click()
        let queue = app.descendants(matching: .any)["queue"].firstMatch
        XCTAssertTrue(queue.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))

        app.trackList.staticTexts["Song 2"].doubleClick()

        XCTAssertTrue(queue.staticTexts["Song 4"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(queue.staticTexts["Song 3"].exists)
    }

    @MainActor func testContextMenuOffersTheTrackActions() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 1"].rightClick()

        for item in ["Play Next", "Add to Queue", "Add to Playlist", "Go to Album", "Go to Artist", "Copy Link", "Remove from Liked Songs"] {
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: XCUIApplication.timeout), item)
        }
        XCTAssertTrue(app.menuItems["Add to Playlist"].isEnabled)
    }

    @MainActor func testRowHeartRemovesTheSongFromLikedSongs() {
        let app = likedSongs()
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch

        row.buttons["Remove from Liked Songs"].click()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.trackList.staticTexts["Song 1"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: XCUIApplication.timeout), .completed)
    }

    @MainActor func testMoreButtonOffersTheTrackActions() {
        let app = likedSongs()
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch
        row.staticTexts["Song 1"].hover()

        row.descendants(matching: .any)["More Options"].firstMatch.click()

        for item in ["Play Next", "Add to Queue", "Go to Album", "Copy Link"] {
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: XCUIApplication.timeout), item)
        }
    }

    @MainActor func testGoToAlbumOpensTheAlbumPage() {
        let app = likedSongs()

        app.trackList.staticTexts["Song 1"].rightClick()
        app.menuItems["Go to Album"].click()

        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testCopyLinkPutsTheWebLinkOnThePasteboard() {
        let app = likedSongs()
        restorePasteboardAfterwards()
        NSPasteboard.general.clearContents()

        app.trackList.staticTexts["Song 1"].rightClick()
        app.menuItems["Copy Link"].click()

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://open.spotify.com/track/uitest1")
    }

    /// The app copies to the real general pasteboard, so put back what the user had there.
    @MainActor private func restorePasteboardAfterwards() {
        let saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(saved)
        }
    }

    @MainActor func testTitleHeaderSortsDescendingOnSecondClick() {
        let app = likedSongs()
        // Header buttons report as not hittable; click their frame instead.
        let title = app.buttons["Title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        title.click()
        // Two clicks inside the double-click interval arrive as one double-click, which sorts once.
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval + 0.1)
        title.click()

        XCTAssertTrue(app.trackList.outlineRows.firstMatch.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// 10,000 liked songs open as one list. Not a frame-rate check: XCUITest's
    /// accessibility snapshot of a table this size takes tens of seconds per query.
    @MainActor func testTenThousandLikedSongsOpen() {
        let app = likedSongs(.largeLibrary, timeout: 60)

        XCTAssertTrue(app.trackList.staticTexts["Song 2"].exists)
    }
}

private extension XCUIApplication {
    var trackList: XCUIElement {
        outlines["trackList"]
    }
}
