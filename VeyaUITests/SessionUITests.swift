import XCTest

/// PBI-102 and PBI-103: restore at launch, recover from a failed restore,
/// and show the reconnect banner.
final class SessionUITests: XCTestCase {
    @MainActor func testSavedSignInRestoresWithoutInteraction() {
        let app = XCUIApplication.launch(.signedIn)

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testFailedRestoreOffersRetryThatSignsIn() {
        let app = XCUIApplication.launch(.restoreFails)
        let tryAgain = app.buttons["Try Again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Sign In Again…"].exists)

        tryAgain.click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testDroppedConnectionShowsReconnectBanner() {
        let app = XCUIApplication.launch(.reconnecting)
        // macOS exposes a combined text element's string as its value, not its label.
        let banner = app.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Offline - reconnecting"))
            .firstMatch

        XCTAssertTrue(banner.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.signedInScreen.exists)
    }
}
