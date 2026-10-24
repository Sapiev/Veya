import XCTest

/// PBI-802: Veya runs in Polish with Polish plurals, durations and dates.
final class LocalizationUITests: XCTestCase {
    @MainActor func testSignInScreenIsInPolish() throws {
        let app = XCUIApplication.launch(.signedOut, locale: "pl_PL")

        XCTAssertTrue(app.staticTexts["Witaj w Veya"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Kontynuuj przez Spotify"].exists)
        try assertAuditPasses(app, "Sign in (Polish)")
    }

    @MainActor func testLibraryAndPlayerAreInPolish() throws {
        let app = XCUIApplication.launch(.signedIn, locale: "pl_PL")

        XCTAssertTrue(app.outlines.staticTexts["Polubione utwory"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.buttons["Odtwórz"].exists)
        try assertAuditPasses(app, "Home (Polish)")
    }

    @MainActor func testAlbumSummaryUsesPolishPluralAndDuration() {
        let app = XCUIApplication.launch(.signedIn, locale: "pl_PL")
        XCTAssertTrue(app.outlines.staticTexts["Polubione utwory"].waitForExistence(timeout: XCUIApplication.timeout))
        app.outlines.buttons["Albumy"].click()
        let album = app.savedItems.buttons["Test Album"]
        XCTAssertTrue(album.waitForExistence(timeout: XCUIApplication.timeout))
        album.click()

        XCTAssertTrue(app.staticTexts["2024 · 3 utwory, 6 min"].waitForExistence(timeout: XCUIApplication.timeout))
    }
}
