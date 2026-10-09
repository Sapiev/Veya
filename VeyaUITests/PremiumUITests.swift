import XCTest

/// PBI-105: a non-Premium account gets an explanation and can sign out.
final class PremiumUITests: XCTestCase {
    @MainActor func testFreeAccountSeesExplanationAndCanSignOut() {
        let app = XCUIApplication.launch(.notPremium)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Sign In with Spotify…"].click()

        XCTAssertTrue(app.staticTexts["Veya Needs Spotify Premium"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.signedInScreen.exists)

        app.buttons["Sign Out"].click()

        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }
}
