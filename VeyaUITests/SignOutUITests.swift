import XCTest

/// PBI-104: sign out from the signed-in view and from the Account menu.
final class SignOutUITests: XCTestCase {
    @MainActor func testSignOutButtonReturnsToSignIn() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Sign Out"].click()

        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testAccountMenuSignOutReturnsToSignIn() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.menuItem("Account", "Sign Out").click()

        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testAccountMenuSignOutIsDisabledWhenSignedOut() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertFalse(app.menuItem("Account", "Sign Out").isEnabled)
    }
}
