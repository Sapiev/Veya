import XCTest

/// PBI-603: the Dock icon's menu controls playback; track notifications start off.
final class DockMenuUITests: XCTestCase {
    @MainActor func testDockMenuShowsTheTrackAndControlsPlayback() {
        let app = XCUIApplication.launch(.signedIn)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: XCUIApplication.timeout))
        play.click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))

        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        // Dock icons never report hittable to another process, so the click goes to the icon's point.
        dock.dockItems["Veya"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(dock.menuItems["Test Track"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(dock.menuItems["Next"].exists)
        XCTAssertTrue(dock.menuItems["Previous"].exists)
        XCTAssertTrue(dock.menuItems["Save to Liked Songs"].exists || dock.menuItems["Remove from Liked Songs"].exists)
        dock.menuItems["Pause"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testTrackNotificationsAreOffByDefault() {
        let app = XCUIApplication.launch(.signedIn)
        app.typeKey(",", modifierFlags: .command)
        let general = app.toolbars.buttons["General"]
        XCTAssertTrue(general.waitForExistence(timeout: XCUIApplication.timeout))
        general.click()

        let notify = app.toggle("Notify when the song changes")
        XCTAssertTrue(notify.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(notify.value as? Int, 0)
    }
}
