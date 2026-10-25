import XCTest

/// PBI-804: crash reports are asked about once after a crash, and changeable in Settings › Advanced.
/// Off by default without asking is covered in UpdatesUITests.
final class CrashReportingUITests: XCTestCase {
    @MainActor private func keepToggle(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Advanced"].click()
        return app.toggle("Keep crash reports")
    }

    /// Checkboxes and switches report their state as 0 or 1.
    @MainActor private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? (element.value as? String == "1")
    }

    @MainActor func testCrashAsksAndKeepingTurnsReportsOn() throws {
        let app = XCUIApplication.launch(.crashedLastTime)
        let keep = app.sheets.buttons["Keep Crash Reports"]
        XCTAssertTrue(keep.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.sheets.staticTexts["Veya Quit Unexpectedly"].exists)

        keep.click()

        XCTAssertFalse(keep.exists)
        let toggle = keepToggle(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(isOn(toggle))
        try assertAuditPasses(app, "Settings › Advanced")
    }

    @MainActor func testDecliningLeavesReportsOff() {
        let app = XCUIApplication.launch(.crashedLastTime)
        let decline = app.sheets.buttons["Don't Keep"]
        XCTAssertTrue(decline.waitForExistence(timeout: XCUIApplication.timeout))

        decline.click()

        XCTAssertFalse(decline.exists)
        let toggle = keepToggle(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(isOn(toggle))
    }
}
