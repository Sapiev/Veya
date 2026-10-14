import XCTest

/// PBI-803: the performance budget. XCTest records the metrics; `scripts/check-performance-budget.sh`
/// enforces the budgets on the result bundle, since a test cannot read its own measurements.
/// Runs on the Debug build against the scenario fakes, so it covers the app's own UI and model
/// cost, not librespot decoding (see docs/performance.md).
final class PerformanceUITests: XCTestCase {
    /// AppKit writes a window snapshot for state restoration a few seconds after launch or
    /// navigation (~0.25 s CPU); waiting it out leaves the steady state to measure.
    private static let settle: TimeInterval = 5

    private static var once: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        return options
    }

    @MainActor func testColdLaunch() {
        let app = XCUIApplication.configured(.signedIn)
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
    }

    @MainActor func testIdle() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        Thread.sleep(forTimeInterval: Self.settle)

        measure(metrics: [XCTMemoryMetric(application: app)], options: Self.once) {
            Thread.sleep(forTimeInterval: 10)
        }
    }

    /// Plays from Liked Songs so the scrubber, the track list and the sidebar all show playback.
    @MainActor func testPlayback() {
        let app = XCUIApplication.launch(.signedIn)
        XCTAssertTrue(app.signedInScreen.waitForExistence(timeout: XCUIApplication.timeout))
        app.signedInScreen.click()
        let song = app.trackList.staticTexts["Song 2"]
        XCTAssertTrue(song.waitForExistence(timeout: XCUIApplication.timeout))
        song.doubleClick()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: XCUIApplication.timeout))
        Thread.sleep(forTimeInterval: Self.settle)

        let metrics: [XCTMetric] = [XCTMemoryMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()]
        measure(metrics: metrics, options: Self.once) {
            Thread.sleep(forTimeInterval: 10)
        }
    }
}
