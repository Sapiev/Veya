import XCTest

/// PBI-409: profiles list public playlists and follows; a playlist's heart follows or unfollows it.
final class ProfileUITests: XCTestCase {
    @MainActor private func openProfile(_ scenario: Scenario = .signedIn) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.sidebarItem("Profile").click()
        return app
    }

    @MainActor func testFriendsPlaylistIsFoundFromTheProfileAndFollowed() throws {
        let app = openProfile()
        XCTAssertTrue(app.showsRoute("UI Test"))
        XCTAssertTrue(app.buttons["Road Trip"].exists)
        try assertAuditPasses(app, "Profile")
        attachScreenshot(of: app.windows.firstMatch, named: "profile")

        app.buttons["Fran"].click()
        XCTAssertTrue(app.showsRoute("Fran"))
        app.buttons["Fran's Mix"].click()
        XCTAssertTrue(app.showsRoute("Fran's Mix"))
        XCTAssertFalse(app.sidebarItem("Fran's Mix").exists)

        app.buttons["Save to Your Library"].click()
        XCTAssertTrue(app.sidebarItem("Fran's Mix").waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Remove from Your Library"].click()
        XCTAssertTrue(app.buttons["Save to Your Library"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.sidebarItem("Fran's Mix").exists)
    }

    @MainActor func testFollowedArtistOpensTheArtistPage() {
        let app = openProfile()
        XCTAssertTrue(app.showsRoute("UI Test"))

        app.scrollViews.buttons["Test Artist"].firstMatch.click()

        XCTAssertTrue(app.showsRoute("Test Artist"))
    }

    @MainActor func testPlaylistOwnerOpensTheirProfile() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.sidebarItem("Road Trip").click()
        XCTAssertTrue(app.showsRoute("Road Trip"))
        // The user's own playlist edits instead of offering a heart.
        XCTAssertFalse(app.buttons["Save to Your Library"].exists)

        app.buttons["By UI Test · 3 songs"].click()

        XCTAssertTrue(app.showsRoute("UI Test"))
    }

    @MainActor func testFollowedPlaylistShowsAFilledHeart() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.sidebarItem("Daily Mix 1").click()

        let heart = app.buttons["Remove from Your Library"]
        XCTAssertTrue(heart.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(heart.value as? String, "On")
    }

    /// Spotify's search has no people, so a pasted profile link finds them; Return opens it too.
    @MainActor func testSearchingAProfileLinkOpensTheProfile() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchField.waitForExistence(timeout: XCUIApplication.timeout))
        app.typeText("https://open.spotify.com/user/fran")

        app.buttons["Open Profile"].click()
        XCTAssertTrue(app.showsRoute("Fran"))

        app.typeKey("f", modifierFlags: .command)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("spotify:user:ui-test\r")
        XCTAssertTrue(app.showsRoute("UI Test"))
    }

    @MainActor func testFailedProfileOffersRetry() {
        let app = openProfile(.libraryFails)

        XCTAssertTrue(app.staticTexts["Couldn't Load Profile"].waitForExistence(timeout: XCUIApplication.timeout))
    }
}
