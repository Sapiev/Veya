import XCTest

/// PBI-801: the browse screens pass the accessibility audit, move by keyboard and follow the Text size setting.
final class AccessibilityBrowseUITests: XCTestCase {
    @MainActor private func signedIn() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor func testHomeAndSidebarPassTheAudit() throws {
        let app = signedIn()
        XCTAssertTrue(app.buttons["Test Album, Test Artist"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Home")
    }

    @MainActor func testSearchPassesTheAudit() throws {
        let app = signedIn()
        app.sidebarItem("Search").click()
        app.typeText("test")
        XCTAssertTrue(app.staticTexts["Top result"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Search")
    }

    @MainActor func testDetailPagePassesTheAudit() throws {
        let app = signedIn()
        app.sidebarItem("Albums").click()
        let album = app.savedItems.buttons["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        album.click()
        XCTAssertTrue(app.showsRoute("Test Album"))
        try assertAuditPasses(app, "Album")
    }

    @MainActor func testSettingsPassesTheAudit() throws {
        let app = signedIn()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.toolbars.buttons["General"].waitForExistence(timeout: XCUIApplication.timeout))
        try assertAuditPasses(app, "Settings")
    }

    @MainActor func testTabReachesTheSidebarAndArrowsWalkIt() {
        let app = signedIn()
        let focusedSidebar = app.outlines.matching(NSPredicate(format: "hasKeyboardFocus == true"))["Sidebar"]
        let searchPage = app.descendants(matching: .any)["searchPage"]

        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(focusedSidebar.waitForExistence(timeout: XCUIApplication.timeout))

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(searchPage.waitForExistence(timeout: XCUIApplication.timeout))
        // Opening Search focuses its field; Shift-Tab returns to the sidebar.
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertTrue(focusedSidebar.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.showsRoute("Liked Songs"))
    }

    @MainActor func testReturnCreatesAPlaylistAndEscapeCancels() {
        let app = signedIn()
        let create = app.buttons["Create"]

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(create.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(create.waitForNonExistence(timeout: XCUIApplication.timeout))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(create.waitForExistence(timeout: XCUIApplication.timeout))
        app.sheets.textFields.firstMatch.click()
        app.typeText("Keyboard Mix")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.showsRoute("Keyboard Mix"))
    }

    @MainActor func testLargestTextSizeEnlargesText() {
        let app = signedIn()
        let greeting = app.staticTexts["greeting"]
        let before = greeting.frame.height

        app.typeKey(",", modifierFlags: .command)
        let picker = app.popUpButtons["Text size"]
        XCTAssertTrue(picker.waitForExistence(timeout: XCUIApplication.timeout))
        picker.click()
        app.menuItems["Largest"].click()
        app.typeKey("w", modifierFlags: .command)

        XCTAssertGreaterThan(greeting.frame.height, before * 1.3)
    }
}
