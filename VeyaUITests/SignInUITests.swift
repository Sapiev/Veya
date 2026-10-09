import XCTest

/// PBI-101: sign in, and recover from a cancelled sign-in.
final class SignInUITests: XCTestCase {
    @MainActor func testSigningInShowsTheSignedInScreen() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Sign In with Spotify…"].click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testCancelledSignInShowsErrorAndRetry() {
        let app = XCUIApplication.launch(.signInCancelled)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Sign In with Spotify…"].click()

        XCTAssertTrue(app.staticTexts["Sign-in was cancelled."].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Try Again"].isEnabled)
    }
}
