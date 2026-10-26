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

    /// The sidebar's selection is the palette tint too, though AppKit draws it as a material.
    @MainActor func testSidebarSelectionUsesTheAccentNotSystemBlue() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        // Only a focused list draws the accent; an unfocused one is the platform's gray.
        app.typeKey(.tab, modifierFlags: [])
        let focused = app.outlines.matching(NSPredicate(format: "hasKeyboardFocus == true"))["Sidebar"]
        XCTAssertTrue(focused.waitForExistence(timeout: XCUIApplication.timeout))
        let item = app.sidebarItem("Home")
        let row = app.outlines.firstMatch.outlineRows.containing(.staticText, identifier: "Home").firstMatch

        // Past the title's end, inside the rounded selection.
        let color = try screenColors(y: item.frame.midY, x: [row.frame.maxX - 24])[0]
        XCTAssertGreaterThan(color.redComponent, color.blueComponent + 0.2, "\(color)")
    }

    @MainActor func testLikedSongsColumnsMenusCopyLinkAndGoToAlbum() {
        let app = likedSongs()
        restorePasteboardAfterwards()

        for title in ["Song 1", "Song 5"] {
            XCTAssertTrue(app.trackList.staticTexts[title].exists, title)
        }
        for column in ["#", "Title", "Album", "Date Added", "Duration"] {
            XCTAssertTrue(app.buttons[column].exists, column)
        }

        app.trackList.staticTexts["Song 1"].rightClick()
        for item in ["Play Next", "Add to Queue", "Add to Playlist", "Go to Album", "Go to Artist", "Copy Link", "Remove from Liked Songs"] {
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: XCUIApplication.timeout), item)
        }
        XCTAssertTrue(app.menuItems["Add to Playlist"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch
        row.staticTexts["Song 1"].hover()
        row.descendants(matching: .any)["More Options"].firstMatch.click()
        for item in ["Play Next", "Add to Queue", "Go to Album", "Copy Link"] {
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: XCUIApplication.timeout), item)
        }
        app.typeKey(.escape, modifierFlags: [])

        NSPasteboard.general.clearContents()
        app.trackList.staticTexts["Song 1"].rightClick()
        app.menuItems["Copy Link"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://open.spotify.com/track/uitest1")

        app.trackList.staticTexts["Song 1"].rightClick()
        app.menuItems["Go to Album"].click()
        XCTAssertTrue(app.showsRoute("Test Album"))
    }

    @MainActor func testTitleHeaderSortsDescendingOnSecondClickThenHeartRemovesSong() {
        let app = likedSongs()
        // Header buttons report as not hittable; click their frame instead.
        let title = app.buttons["Title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        title.click()
        // Two clicks inside the double-click interval arrive as one double-click, which sorts once.
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval + 0.1)
        title.click()

        XCTAssertTrue(app.trackList.outlineRows.firstMatch.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))

        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch
        row.buttons["Remove from Liked Songs"].click()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.trackList.staticTexts["Song 1"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: XCUIApplication.timeout), .completed)
    }

    /// The region locked Song 3 refuses to play (nothing plays yet), then Return plays the selected Song 4.
    @MainActor func testRegionLockedRowRefusesToPlayThenReturnPlaysTheSelectedRow() {
        let app = likedSongs()
        let locked = app.trackList.staticTexts["Song 3"]
        XCTAssertTrue(locked.waitForExistence(timeout: XCUIApplication.timeout))

        locked.doubleClick()
        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.buttons["Pause"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertFalse(app.trackList.images["Now Playing"].exists)

        app.trackList.staticTexts["Song 4"].click()
        // Return right after the click can beat the selection to the app's key handler.
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 4").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// Double-click plays and marks the row; the playing, selected row's title stays readable.
    @MainActor func testDoubleClickPlaysTheRowAndItsSelectedTitleStaysReadable() throws {
        let app = likedSongs()
        let title = app.trackList.staticTexts["Song 2"]

        title.doubleClick()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.images["Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value == %@", "Song 2")).count, 2)

        // The playing row's accent title switches to the accent's ink once the row is selected in the accent.
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 2").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)

        let pixels = try XCTUnwrap(ScreenPixels(XCUIScreen.main.screenshot()))
        XCTAssertGreaterThan(pixels.contrast(in: title.frame), 4.5)
    }

    /// The focused selection and the right-click outline are the palette tint (Veya's red by default), never the system blue.
    @MainActor func testSelectionAndRightClickOutlineUseTheAccentNotSystemBlue() throws {
        let app = likedSongs()
        let title = app.trackList.staticTexts["Song 2"]
        title.click()
        let row = app.trackList.outlineRows.containing(.staticText, identifier: "Song 2").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)

        // Just left of the title, between the artwork and the text: only the selection is drawn there.
        let color = try screenColors(y: title.frame.midY, x: [title.frame.minX - 6])[0]
        XCTAssertGreaterThan(color.redComponent, color.blueComponent + 0.2, "\(color)")

        let outlined = app.trackList.staticTexts["Song 4"]
        let outlinedRow = app.trackList.outlineRows.containing(.staticText, identifier: "Song 4").firstMatch
        outlined.rightClick()
        XCTAssertTrue(app.menuItems["Play Next"].waitForExistence(timeout: XCUIApplication.timeout))

        // Across the row's leading edge, which the outline crosses and the menu never covers.
        let colors = try screenColors(y: outlined.frame.midY, x: Array(stride(from: outlinedRow.frame.minX, to: outlinedRow.frame.minX + 30, by: 0.5)))
        XCTAssertFalse(colors.contains { $0.blueComponent > $0.redComponent + 0.2 }, "\(colors)")
        XCTAssertTrue(colors.contains { $0.redComponent > $0.blueComponent + 0.3 }, "\(colors)")
    }

    /// The compact, icon-only sidebar keeps the accent selection after a click, which never focuses the list.
    @MainActor func testCompactSidebarSelectionUsesTheAccentAndSelectedIconStaysReadable() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Collapse Sidebar"].click()
        XCTAssertTrue(app.buttons["Expand Sidebar"].waitForExistence(timeout: XCUIApplication.timeout))
        let sidebar = app.outlines.firstMatch
        // Icon-only rows keep their names as labels; the collapse animation leaves them briefly not hittable.
        let row = sidebar.outlineRows.containing(NSPredicate(format: "label == 'Road Trip'")).firstMatch
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.showsRoute("Road Trip"))
        attachScreenshot(of: app.windows.firstMatch, named: "compact-sidebar-selection")

        // Beside the icon, inside the rounded selection.
        let colors = try screenColors(y: row.frame.midY, x: [row.frame.minX + 14, row.frame.maxX - 14])
        XCTAssertTrue(colors.contains { $0.redComponent > $0.blueComponent + 0.2 }, "\(colors)")
        XCTAssertFalse(colors.contains { $0.blueComponent > $0.redComponent + 0.2 }, "\(colors)")

        // A selected compact icon turns the row's text color, not the accent it would vanish into.
        let searchRow = sidebar.outlineRows.containing(NSPredicate(format: "label == 'Search'")).firstMatch
        searchRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.showsRoute("Search"))

        let pixels = try XCTUnwrap(ScreenPixels(XCUIScreen.main.screenshot()))
        let icon = CGRect(x: searchRow.frame.midX - 12, y: searchRow.frame.midY - 12, width: 24, height: 24)
        XCTAssertGreaterThan(pixels.contrast(in: icon), 3)
    }

    /// The compact sidebar shows no equalizer on the playing playlist; VoiceOver still hears it.
    @MainActor func testCompactSidebarHidesEqualizerOnPlayingPlaylist() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Road Trip"].click()
        XCTAssertTrue(app.showsRoute("Road Trip"))
        app.trackList.staticTexts["Song 1"].doubleClick()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Collapse Sidebar"].click()
        XCTAssertTrue(app.buttons["Expand Sidebar"].waitForExistence(timeout: XCUIApplication.timeout))
        let row = app.outlines.firstMatch.outlineRows.containing(NSPredicate(format: "label == 'Road Trip'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: XCUIApplication.timeout))
        attachScreenshot(of: app.windows.firstMatch, named: "compact-sidebar-playing")
        let icon = app.outlines.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == 'Road Trip'")).firstMatch
        XCTAssertEqual(icon.value as? String, "Private, Playing")
        XCTAssertFalse(app.outlines.firstMatch.images["Now Playing"].exists)
    }

    /// Screen colors along a row of screen points.
    @MainActor private func screenColors(y: CGFloat, x: [CGFloat]) throws -> [NSColor] {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCUIScreen.main.screenshot().pngRepresentation))
        let scale = try CGFloat(rep.pixelsWide) / XCTUnwrap(NSScreen.screens.first).frame.width
        return try x.map { try XCTUnwrap(rep.colorAt(x: Int($0 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)) }
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

    /// The app copies to the real general pasteboard, so put back what the user had there.
    @MainActor private func restorePasteboardAfterwards() {
        let saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(saved)
        }
    }

    /// 10,000 liked songs open as one list. Not a frame-rate check: XCUITest's
    /// accessibility snapshot of a table this size takes tens of seconds per query.
    @MainActor func testTenThousandLikedSongsOpen() {
        let app = likedSongs(.largeLibrary, timeout: 180)

        XCTAssertTrue(app.trackList.staticTexts["Song 2"].exists)
    }
}
