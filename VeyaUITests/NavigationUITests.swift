import XCTest

/// PBI-401: sidebar destinations and back/forward history; PBI-304: playlist folders.
/// PBI-405: the top bar's More Options menu.
final class NavigationUITests: XCTestCase {
    @MainActor func testMoreOptionsOpensAdaptiveColorSettings() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.menuButtons["More Options"].click()
        app.menuItems["Adaptive Color…"].click()

        XCTAssertTrue(app.popUpButtons["Window colors"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testMoreOptionsOpensTheFullWindowPlayer() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.staticTexts["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))

        app.menuButtons["More Options"].click()
        app.menuItems["Full-Window Now Playing"].click()

        XCTAssertTrue(app.buttons["Hello from the first line"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testSidebarListsDestinationsAndPlaylists() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        let sidebar = app.outlines.firstMatch
        for item in ["Home", "Search", "Liked Songs", "Albums", "Artists", "Podcasts", "Road Trip"] {
            XCTAssertTrue(app.sidebarItem(item).exists, item)
        }
        XCTAssertTrue(app.staticTexts["greeting"].exists)
        // One New Playlist button, at the sidebar's foot; the Playlists header has none.
        XCTAssertEqual(app.buttons.matching(identifier: "New Playlist").count, 1)
        XCTAssertTrue(app.buttons["New Playlist"].isEnabled)
    }

    /// The window buttons sit inside the floating sidebar panel, 20 pt in and 18 pt down as in the design.
    /// A click or a new page title re-lays out the titlebar, so they must stay there afterwards too.
    @MainActor func testWindowButtonsSitInsideTheSidebarPanel() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        assertWindowButtonsInset(app)
        app.staticTexts["greeting"].click()
        assertWindowButtonsInset(app)
        for page in ["Liked Songs", "Road Trip"] {
            app.sidebarItem(page).click()
            XCTAssertTrue(app.showsRoute(page), page)
            assertWindowButtonsInset(app)
        }
        app.sidebarItem("Home").click()
        XCTAssertTrue(app.staticTexts["greeting"].waitForExistence(timeout: XCUIApplication.timeout))
        assertWindowButtonsInset(app)
    }

    @MainActor private func assertWindowButtonsInset(_ app: XCUIApplication, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].frame
        XCTAssertEqual(close.minX - window.minX, 20, accuracy: 1, line: line)
        XCTAssertEqual(close.minY - window.minY, 18, accuracy: 1, line: line)
    }

    /// The sidebar is a custom panel, so the View menu carries its toggle.
    @MainActor func testViewMenuHidesAndShowsTheSidebar() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.menuItem("View", "Hide Sidebar").click()
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.menuItem("View", "Show Sidebar").click()
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// Compact sidebar: icons only, rows still named for VoiceOver and still navigating.
    @MainActor func testCompactSidebarShowsIconsThatStillNavigate() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let sidebar = app.outlines.firstMatch
        let fullWidth = sidebar.frame.width

        app.menuItem("View", "Collapse Sidebar").click()
        XCTAssertTrue(sidebar.staticTexts["Home"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertLessThan(sidebar.frame.width, fullWidth / 2)
        let liked = sidebar.images["Liked Songs"]
        XCTAssertTrue(liked.exists)
        // Section titles give way to hairline dividers that VoiceOver still names, leaving square cells with bigger icons.
        XCTAssertLessThanOrEqual(sidebar.staticTexts["Playlists"].frame.height, 2)
        XCTAssertFalse(app.sidebarItem("Albums").exists)
        XCTAssertEqual(liked.frame.width, liked.frame.height, accuracy: 12)
        XCTAssertGreaterThanOrEqual(liked.frame.height, 36)
        // Cells laid out at full width must not keep their old inset after the collapse.
        XCTAssertEqual(liked.frame.midX, sidebar.frame.midX, accuracy: 1)
        XCTAssertTrue(app.buttons["New Playlist"].exists)
        try assertAuditPasses(app, "Compact sidebar")
        attachScreenshot(of: app.windows.firstMatch, named: "compact-sidebar")

        liked.click()
        XCTAssertTrue(app.trackList.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Expand Sidebar"].click()
        XCTAssertTrue(app.sidebarItem("Home").waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// With the sidebar hidden the window buttons sit over the page, so the top bar starts past them.
    @MainActor func testTopBarClearsWindowButtonsWithSidebarHidden() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.menuItem("View", "Hide Sidebar").click()
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))
        let window = app.windows.firstMatch
        let zoom = window.buttons[XCUIIdentifierFullScreenWindow].frame
        let back = window.buttons["Back"].frame
        XCTAssertGreaterThan(back.minX, zoom.maxX)
    }

    /// Saved artists, albums and podcasts list in the sidebar and open their page.
    @MainActor func testSidebarSectionsListSavedItemsThatOpenTheirPage() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let sidebar = app.outlines.firstMatch

        for item in ["Test Artist", "Test Album", "Test Podcast"] {
            let row = sidebar.staticTexts[item]
            XCTAssertTrue(row.waitForExistence(timeout: XCUIApplication.timeout), item)
            row.click()
            XCTAssertTrue(app.showsRoute(item), item)
        }
    }

    @MainActor func testSidebarMarksThePlayingAlbum() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let sidebar = app.outlines.firstMatch
        let row = sidebar.outlineRows.containing(NSPredicate(format: "label == 'Test Album' OR value == 'Test Album'"))
        XCTAssertTrue(sidebar.staticTexts["Test Album"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(row.images["Now Playing"].exists)

        sidebar.staticTexts["Test Album"].click()
        app.buttons["pagePlay"].click()

        XCTAssertTrue(row.images["Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testSidebarSectionHeaderOpensTheFullGrid() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.sidebarItem("Albums").click()

        XCTAssertTrue(app.showsRoute("Albums"))
        XCTAssertTrue(app.savedItems.buttons["Test Album"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    /// PBI-304: folders start collapsed and open to show the playlists inside.
    @MainActor func testPlaylistFolderExpandsToShowItsPlaylists() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(sidebar.staticTexts["Mixes"].exists)
        XCTAssertFalse(sidebar.staticTexts["Morning Mix"].exists)

        sidebar.outlineRows.containing(NSPredicate(format: "label == 'Mixes' OR value == 'Mixes'")).disclosureTriangles.firstMatch.click()

        XCTAssertTrue(sidebar.staticTexts["Morning Mix"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testSelectingAPlaylistShowsIt() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.outlines.staticTexts["Road Trip"].click()

        XCTAssertTrue(app.showsRoute("Road Trip"))
    }

    @MainActor func testKeyboardBackAndForward() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.staticTexts["Liked Songs"].click()
        app.sidebarItem("Albums").click()
        XCTAssertEqual(app.routeTitle.value as? String, "Albums")

        app.typeKey("[", modifierFlags: .command)
        XCTAssertEqual(app.routeTitle.value as? String, "Liked Songs")

        app.typeKey("]", modifierFlags: .command)
        XCTAssertEqual(app.routeTitle.value as? String, "Albums")
    }

    @MainActor func testTopBarBackAndForward() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let back = app.buttons["Back"]
        let forward = app.buttons["Forward"]
        XCTAssertFalse(back.isEnabled)

        app.sidebarItem("Artists").click()
        back.click()
        XCTAssertTrue(app.staticTexts["greeting"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(back.isEnabled)

        forward.click()
        XCTAssertEqual(app.routeTitle.value as? String, "Artists")
        XCTAssertFalse(forward.isEnabled)
    }

    @MainActor func testGoMenuIsDisabledWithoutHistory() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertFalse(app.menuItem("Go", "Back").isEnabled)
    }
}
