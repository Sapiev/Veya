import XCTest

/// PBI-902: Check for Updates in the app menu, and update preferences in Settings › Advanced.
final class UpdatesUITests: XCTestCase {
    /// Checkboxes and switches report their state as 0 or 1.
    @MainActor private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? (element.value as? String == "1")
    }

    @MainActor func testCheckForUpdatesIsInTheAppMenu() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertTrue(app.menuItem("Veya", "Check for Updates…").exists)
    }

    @MainActor func testBetaVersionsAreOptIn() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Advanced"].click()

        let beta = app.toggle("Include beta versions")
        XCTAssertTrue(beta.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.toggle("Check for updates automatically").exists)
        XCTAssertFalse(isOn(beta))

        beta.click()

        XCTAssertTrue(isOn(beta))
        try assertAuditPasses(app, "Settings › Advanced")
    }
}
