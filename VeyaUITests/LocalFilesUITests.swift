import XCTest

/// PBI-703: local folders in Settings > Playback, and `spotify:local:` playlist entries
/// that play, or explain the 44.1 kHz limit when librespot can't play them.
final class LocalFilesUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication.launch(.localFiles)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        return app
    }

    @MainActor private func localMix(_ app: XCUIApplication) {
        app.sidebarItem("Local Mix").click()
        XCTAssertTrue(app.showsRoute("Local Mix"))
    }

    @MainActor func testChosenFoldersAreListedAndRemovable() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Playback"].click()

        XCTAssertTrue(app.staticTexts["Local Files"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Veya Music"].exists)
        XCTAssertTrue(app.staticTexts["Veya Mixes"].exists)
        XCTAssertTrue(app.buttons["Add Folder…"].exists)
        XCTAssertTrue(app.staticTexts[
            "Only MP3, MP4 and FLAC files sampled at 44.1 kHz play, matched to local files in your playlists."
        ].exists)

        app.buttons["Remove Veya Music"].click()

        XCTAssertTrue(app.staticTexts["Veya Music"].waitForNonExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts["Veya Mixes"].exists)
    }

    @MainActor func testUnplayableLocalFileExplainsTheLimitThenLocalEntryShowsItsTitleAndPlays() {
        let app = launch()
        localMix(app)
        let hiRes = app.trackList.staticTexts["Hi-Res Song"]
        XCTAssertTrue(hiRes.waitForExistence(timeout: XCUIApplication.timeout))

        hiRes.doubleClick()

        XCTAssertTrue(app.staticTexts["Couldn't Play “Hi-Res Song”"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.staticTexts[
            "Veya plays local MP3, MP4 and FLAC files sampled at 44.1 kHz from the folders in Settings > Playback."
        ].exists)
        app.sheets.buttons["OK"].click()
        XCTAssertTrue(app.staticTexts["Couldn't Play “Hi-Res Song”"].waitForNonExistence(timeout: XCUIApplication.timeout))

        let song = app.trackList.staticTexts["Local Song"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.staticTexts["Local Artist"].exists)

        song.doubleClick()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.trackList.images["Now Playing"].waitForExistence(timeout: XCUIApplication.timeout))
    }
}
