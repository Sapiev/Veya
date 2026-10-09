import XCTest

/// Mirrors Veya's `UITestScenario`; an unknown name crashes the app at launch.
enum Scenario: String {
    case signedOut
    case signInCancelled
    case signedIn
    case restoreFails
    case reconnecting
    case notPremium
    case largeLibrary
}

@MainActor
extension XCUIApplication {
    static let timeout: TimeInterval = 5

    /// Launches Veya against in-memory fakes; it never reaches Spotify or the Keychain.
    static func launch(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VEYA_UI_TEST_SCENARIO"] = scenario.rawValue
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    var signInScreen: XCUIElement {
        staticTexts["Sign In to Veya"]
    }

    var signedInScreen: XCUIElement {
        outlines.staticTexts["Liked Songs"]
    }

    /// The heading of the screen the main window shows.
    var routeTitle: XCUIElement {
        staticTexts["routeTitle"]
    }

    func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        menuBars.menuBarItems[menu].click()
        return menuBars.menuItems[item]
    }
}
