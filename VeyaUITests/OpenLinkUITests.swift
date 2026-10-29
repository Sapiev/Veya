import XCTest

/// PBI-606: links from other apps open pages; a track or episode link waits for the user's confirmation.
final class OpenLinkUITests: XCTestCase {
    @MainActor private func signedIn() -> XCUIApplication {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    /// An outside track link must not start playback by itself: it fills the Open Link sheet, and Open plays.
    @MainActor func testAnOutsideTrackLinkWaitsForConfirmationBeforePlaying() throws {
        let app = signedIn()

        try app.open(XCTUnwrap(URL(string: "veya://track/uitest")))

        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(field.value as? String, "spotify:track:uitest")
        XCTAssertFalse(app.buttons["Pause"].exists, "nothing plays before the user confirms")
        attachScreenshot(of: app.sheets.firstMatch, named: "open-link-confirm")

        app.sheets.buttons["Open"].click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testCancellingAnOutsideTrackLinkPlaysNothing() throws {
        let app = signedIn()

        try app.open(XCTUnwrap(URL(string: "veya://episode/uitest")))
        XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: XCUIApplication.timeout))
        app.sheets.buttons["Cancel"].click()

        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.buttons["Pause"].exists)
    }

    @MainActor func testMalformedOutsideLinksAreIgnored() throws {
        let app = signedIn()

        for link in ["veya://track", "veya://track/uitest/extra", "veya://nonsense/uitest", "veya://track/\(String(repeating: "a", count: 40))"] {
            try app.open(XCTUnwrap(URL(string: link)))
        }

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["Pause"].exists)
    }

    /// A link that arrives on the welcome screen waits for the sign-in, then opens its page.
    @MainActor func testALinkOpenedBeforeSignInOpensAfterIt() throws {
        let app = XCUIApplication.launch(.signedOut)
        XCTAssertTrue(app.signInScreen.waitForExistence(timeout: XCUIApplication.timeout))

        try app.open(XCTUnwrap(URL(string: "veya://playlist/uitest")))
        app.buttons["Continue with Spotify"].click()

        XCTAssertTrue(app.showsRoute("Road Trip"))
    }

    /// With the main window closed the link still reaches the app and brings the window back.
    @MainActor func testALinkOpenedWithTheWindowClosedShowsItsPage() throws {
        let app = signedIn()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.signedInScreen.waitForNonExistence(timeout: XCUIApplication.timeout))

        try app.open(XCTUnwrap(URL(string: "veya://playlist/uitest")))

        XCTAssertTrue(app.showsRoute("Road Trip"))
    }
}
