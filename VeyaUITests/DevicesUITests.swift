import XCTest

/// PBI-502: the device picker lists the account's Connect devices and moves playback.
final class DevicesUITests: XCTestCase {
    @MainActor private func openDevices(_ scenario: Scenario = .connectDevices) -> XCUIApplication {
        let app = XCUIApplication.launch(scenario)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.buttons["Devices"].firstMatch.click()
        return app
    }

    @MainActor private func device(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.popovers.buttons[name]
    }

    @MainActor func testPopoverListsThisMacAndTheAccountsDevicesWithTheActiveOneMarked() {
        let app = openDevices()

        let phone = device(app, "Pixel")
        XCTAssertTrue(phone.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(phone.value as? String, "Playing, volume 10%")
        XCTAssertTrue(phone.isSelected)
        XCTAssertTrue(phone.isEnabled, "the active row stays reachable")
        XCTAssertTrue(app.popovers.staticTexts["Devices"].exists)
        XCTAssertEqual(device(app, "This Mac").value as? String, "Volume 100%")
        XCTAssertEqual(device(app, "Kitchen Speaker").value as? String, "Volume 50%")
        XCTAssertFalse(device(app, "Studio Mac").exists, "our own device is shown as This Mac")
    }

    @MainActor func testChoosingADeviceTransfersPlaybackToIt() {
        let app = openDevices()
        let speaker = device(app, "Kitchen Speaker")
        XCTAssertTrue(speaker.waitForExistence(timeout: XCUIApplication.timeout))

        speaker.click()

        let playing = NSPredicate(format: "value == 'Playing, volume 50%'")
        expectation(for: playing, evaluatedWith: speaker)
        waitForExpectations(timeout: XCUIApplication.timeout)
        XCTAssertEqual(device(app, "Pixel").value as? String, "Volume 10%")
        XCTAssertFalse(device(app, "Pixel").isSelected)
    }

    @MainActor func testAFailedTransferIsShownInThePopover() {
        let app = openDevices()
        let tv = device(app, "Living Room TV")
        XCTAssertTrue(tv.waitForExistence(timeout: XCUIApplication.timeout))

        tv.click()

        XCTAssertTrue(app.popovers.staticTexts["Couldn't move playback. Try again."]
            .waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(device(app, "Pixel").value as? String, "Playing, volume 10%")
    }

    @MainActor func testTheDevicesButtonNamesTheDevicePlayingElsewhere() {
        let app = XCUIApplication.launch(.connectDevices)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertEqual(app.buttons["Devices"].firstMatch.value as? String, "Playing on Pixel")
    }

    @MainActor func testPopoverExplainsWhenLocalNetworkAccessIsOff() throws {
        let app = openDevices(.localNetworkDenied)

        let notice = app.popovers.staticTexts["Local Network Access Is Off"]
        XCTAssertTrue(notice.waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertTrue(app.popovers.buttons["Open Privacy Settings"].exists)
        XCTAssertTrue(device(app, "Pixel").exists, "account devices still list")
        try assertAuditPasses(app, "Devices without local network")
    }

    @MainActor func testPopoverHasNoNoticeWithLocalNetworkAccess() {
        let app = openDevices()

        XCTAssertTrue(device(app, "Pixel").waitForExistence(timeout: XCUIApplication.timeout))
        XCTAssertFalse(app.popovers.staticTexts["Local Network Access Is Off"].exists)
    }
}
