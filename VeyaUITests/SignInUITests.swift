import XCTest

/// PBI-101: sign in from the welcome screen, and recover from a cancelled or failed sign-in.
final class SignInUITests: XCTestCase {
    @MainActor func testWelcomeScreenShowsCopyAndButton() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        XCTAssertTrue(app.staticTexts["Your Spotify library, playlists and liked songs in a player that takes its colors from the music."].exists)
        XCTAssertTrue(app.staticTexts["You'll sign in on Spotify's own page. Veya never sees your password."].exists)
        XCTAssertTrue(app.buttons["Continue with Spotify"].isEnabled)
        XCTAssertFalse(app.outlines.firstMatch.exists, "The welcome screen has no sidebar")
    }

    @MainActor func testSigningInShowsTheSignedInScreen() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.buttons["Continue with Spotify"].click()

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testReturnStartsSignIn() {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testCancelledSignInReturnsQuietly() {
        let app = XCUIApplication.launch(.signInCancelled)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let button = app.buttons["Continue with Spotify"]

        button.click()

        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.staticTexts["Sign-in was cancelled."].exists)
    }

    @MainActor func testFailedSignInShowsErrorWithoutMovingTheFootnote() {
        let app = XCUIApplication.launch(.signInFails)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        let footnote = app.staticTexts["You'll sign in on Spotify's own page. Veya never sees your password."]
        let before = footnote.frame

        app.buttons["Continue with Spotify"].click()

        XCTAssertTrue(app.staticTexts["Couldn't reach Spotify. Check your connection and try again."]
            .waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Continue with Spotify"].isEnabled)
        XCTAssertEqual(footnote.frame, before)
    }
}
