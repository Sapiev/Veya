import XCTest

@MainActor
extension XCTestCase {
    /// Kept in the result bundle even when the test passes, so `scripts/ui-screenshots.sh` can export it.
    func attachScreenshot(of element: XCUIElement, named name: String) {
        let shot = XCTAttachment(screenshot: element.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
