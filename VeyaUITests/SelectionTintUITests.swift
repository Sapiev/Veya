import XCTest

/// PBI-803: the selection tint swizzles AppKit selectors; a debug build traps at launch if an OS update removed one.
final class SelectionTintUITests: XCTestCase {
    @MainActor func testAppLaunchesWithEveryTintedSelectorPresent() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }
}
