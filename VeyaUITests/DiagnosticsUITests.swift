import XCTest

/// PBI-006: Help › Export Diagnostics is reachable from the menu bar.
final class DiagnosticsUITests: XCTestCase {
    @MainActor func testHelpMenuOffersExportDiagnostics() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertTrue(app.menuItem("Help", "Export Diagnostics…").isEnabled)
    }
}
