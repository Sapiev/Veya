import XCTest

/// PBI-902: Check for Updates in the app menu, and update preferences in Settings › Advanced.
final class UpdatesUITests: XCTestCase {
    /// Checkboxes and switches report their state as 0 or 1.
    @MainActor private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? (element.value as? String == "1")
    }

    /// Also PBI-804: crash reports are off by default without asking (same Advanced pane).
    @MainActor func testCheckForUpdatesIsInTheAppMenuAndBetaVersionsAndCrashReportsAreOptIn() throws {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.sheets.staticTexts["Veya Quit Unexpectedly"].exists)

        XCTAssertTrue(app.menuItem("Veya", "Check for Updates…").exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Advanced"].click()

        let beta = app.toggle("Include beta versions")
        XCTAssertTrue(beta.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.toggle("Check for updates automatically").exists)
        XCTAssertFalse(isOn(beta))
        let crashReports = app.toggle("Keep crash reports")
        XCTAssertTrue(crashReports.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(isOn(crashReports))

        beta.click()

        XCTAssertTrue(isOn(beta))
        try assertAuditPasses(app, "Settings › Advanced")
    }
}
