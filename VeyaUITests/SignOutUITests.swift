import XCTest

/// PBI-104: sign out from the Account menu.
final class SignOutUITests: XCTestCase {
    /// PBI-102: a saved sign-in restores without interaction (the first wait below).
    @MainActor func testAccountMenuSignOutReturnsToSignIn() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.menuItem("Account", "Sign Out").click()

        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }
}
