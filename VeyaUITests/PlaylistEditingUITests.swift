import XCTest

/// PBI-702: create, rename, describe, delete and publish playlists; add, remove
/// and reorder tracks with undo; a conflicting edit rolls back with a notice.
final class PlaylistEditingUITests: XCTestCase {
    @MainActor private func launch(_ scenario: Scenario = .signedIn) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor private func roadTrip(_ scenario: Scenario = .signedIn) -> XCUIApplication {
        let app = launch(scenario)
        app.sidebarItem("Road Trip").click()
        XCTAssertTrue(app.showsRoute("Road Trip"))
        XCTAssertTrue(app.trackList.staticTexts["Song 5"].waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor private func sidebarMenu(_ app: XCUIApplication, on row: String, choose item: String) {
        app.sidebarItem(row).rightClick()
        let menuItem = app.outlines.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: XCUIApplication.timeout), item)
        menuItem.click()
    }

    /// New playlist sheet (name required, Cancel creates nothing), then create with a description, new folder,
    /// add a track from Liked Songs, and delete last because the others need Road Trip.
    @MainActor func testNewPlaylistFolderAddTrackAndDelete() {
        let app = launch()
        let rows = app.outlines.staticTexts.count

        app.buttons["New Playlist"].firstMatch.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(sheet.buttons["Create"].isEnabled)
        sheet.textFields.element(boundBy: 0).click()
        sheet.textFields.element(boundBy: 0).typeText("   ")
        XCTAssertFalse(sheet.buttons["Create"].isEnabled)
        sheet.buttons["Cancel"].click()
        XCTAssertFalse(sheet.waitForExistence(timeout: 1))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForExistence(timeout: XCUIApplication.timeout))
        sheet.buttons["Cancel"].click()
        XCTAssertFalse(sheet.waitForExistence(timeout: 1))
        XCTAssertEqual(app.outlines.staticTexts.count, rows)

        sidebarMenu(app, on: "Home", choose: "New Playlist")
        XCTAssertTrue(sheet.waitForExistence(timeout: XCUIApplication.timeout))
        let name = sheet.textFields.element(boundBy: 0)
        name.click()
        name.typeText("Night Drive")
        let description = sheet.textFields.element(boundBy: 1)
        description.click()
        description.typeText("Songs after dark")
        sheet.buttons["Create"].click()

        XCTAssertTrue(app.showsRoute("Night Drive"))
        XCTAssertTrue(app.staticTexts["Songs after dark"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.sidebarItem("Night Drive").exists)

        sidebarMenu(app, on: "Home", choose: "New Folder")
        XCTAssertTrue(app.sidebarItem("Untitled Folder").waitForExistence(timeout: XCUIApplication.timeout))

        app.sidebarItem("Liked Songs").click()
        let song = app.trackList.staticTexts["Song 4"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))

        song.rightClick()
        app.menuItems["Add to Playlist"].click()
        let target = app.menuItems["Road Trip"]
        XCTAssertTrue(target.waitForExistence(timeout: XCUIApplication.timeout))
        target.click()

        app.sidebarItem("Road Trip").click()
        XCTAssertTrue(app.showsRoute("Road Trip"))
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 2", "Song 5", "Song 4"]))

        sidebarMenu(app, on: "Road Trip", choose: "Delete Playlist")
        XCTAssertTrue(app.staticTexts["Delete “Road Trip”?"].waitForExistence(timeout: XCUIApplication.timeout))
        app.sheets.buttons["Delete"].click()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sidebarItem("Road Trip"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: XCUIApplication.timeout), .completed)
    }

    /// Visibility lock, edit details, photo, then rename last because it ends the "Road Trip" name.
    @MainActor func testRoadTripLockDetailsPhotoAndRename() {
        let app = roadTrip()

        // The lock follows Make Public / Make Private, and the menu offers Make Public again afterwards.
        let lock = app.outlines.images["Private"]
        XCTAssertTrue(lock.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Private"].exists)

        sidebarMenu(app, on: "Road Trip", choose: "Make Public")
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: lock)
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: XCUIApplication.timeout), .completed)
        XCTAssertTrue(app.staticTexts["Public"].waitForExistence(timeout: XCUIApplication.timeout))

        sidebarMenu(app, on: "Road Trip", choose: "Make Private")
        XCTAssertTrue(lock.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Private"].waitForExistence(timeout: XCUIApplication.timeout))
        app.sidebarItem("Road Trip").rightClick()
        XCTAssertTrue(app.outlines.menuItems["Make Public"].waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(.escape, modifierFlags: [])

        // Edit Details changes the description.
        app.buttons["Edit Details…"].click()
        var sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: XCUIApplication.timeout))
        let description = sheet.textFields.matching(NSPredicate(format: "value == %@", "Songs for the road")).firstMatch
        description.click()
        description.typeKey("a", modifierFlags: .command)
        description.typeText("Night drive")
        sheet.buttons["Save"].click()

        XCTAssertTrue(app.staticTexts["Night drive"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.staticTexts["Songs for the road"].exists)

        // The scenario hands over a 1600 x 1200 PNG in place of the open panel, and its
        // service takes only a JPEG of at most 640 px a side, so the photo shows only
        // once the app has scaled and re-encoded it.
        XCTAssertFalse(app.images["Artwork"].exists)
        app.buttons["Edit Details…"].click()
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: XCUIApplication.timeout))
        sheet.buttons["Choose Photo…"].click()
        sheet.buttons["Save"].click()

        XCTAssertTrue(app.images["Artwork"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.staticTexts["Couldn't Change Playlist"].exists)

        sidebarMenu(app, on: "Road Trip", choose: "Rename…")
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: XCUIApplication.timeout))
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Highway")
        app.sheets.buttons["Rename"].click()

        XCTAssertTrue(app.sidebarItem("Highway").waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.sidebarItem("Road Trip").exists)
    }

    /// Delete key and drag-reorder each end undone, so the list is whole again for the remove, undo and redo.
    @MainActor func testTrackDeleteReorderRemoveAndUndo() {
        let app = roadTrip()

        app.trackList.staticTexts["Song 1"].click()
        let selectedRow = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: selectedRow)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: XCUIApplication.timeout), .completed)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.waitForSongs(["Song 2", "Song 5"]))

        app.menuItem("Edit", "Undo").click()
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 2", "Song 5"]))

        let last = app.trackList.outlineRows.containing(.staticText, identifier: "Song 5").firstMatch
        let first = app.trackList.outlineRows.containing(.staticText, identifier: "Song 1").firstMatch

        // On macOS a drag is a click held and moved; `press` is a Force Touch.
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
            forDuration: 0.5, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
            withVelocity: .slow, thenHoldForDuration: 0.5
        )
        XCTAssertTrue(app.waitForSongs(["Song 5", "Song 1", "Song 2"]))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 2", "Song 5"]))

        app.trackList.staticTexts["Song 2"].rightClick()
        app.menuItems["Remove from This Playlist"].click()
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 5"]))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 2", "Song 5"]))

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 5"]))
    }

    @MainActor func testAConflictUndoesTheEditAndSaysSo() {
        let app = roadTrip(.playlistConflict)

        app.trackList.staticTexts["Song 2"].rightClick()
        app.menuItems["Remove from This Playlist"].click()

        let notice = app.staticTexts["This playlist changed somewhere else. Your change was undone."]
        XCTAssertTrue(notice.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.waitForSongs(["Song 1", "Song 2", "Song 5"]))
        app.sheets.buttons["OK"].click()
    }
}

@MainActor
extension XCUIApplication {
    /// Waits until the track list shows exactly `titles`, in order.
    func waitForSongs(_ titles: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(Self.timeout)
        repeat {
            let shown = trackList.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Song '")).allElementsBoundByIndex
                .compactMap { $0.value as? String }
            if shown == titles {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }
}
