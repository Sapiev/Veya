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
    case emptyLibrary
    case libraryFails
    case recentlyPlayedNeedsSignIn
    case webAPINotConnected
}

@MainActor
extension XCUIApplication {
    static let timeout: TimeInterval = 5

    /// Launches Veya against in-memory fakes; it never reaches Spotify or the Keychain.
    static func launch(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VEYA_UI_TEST_SCENARIO"] = scenario.rawValue
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // Tests share the app's defaults, so pin the main window over any frame a user saved; AppKit fits it to the screen.
        app.launchArguments += ["-NSWindow Frame main", "0 0 1200 2000"]
        app.launch()
        return app
    }

    var signInScreen: XCUIElement {
        staticTexts["Sign In to Veya"]
    }

    var signedInScreen: XCUIElement {
        outlines.staticTexts["Liked Songs"]
    }

    /// A sidebar row by name; "Albums", "Artists" and "Podcasts" are section headers that open the full page.
    func sidebarItem(_ name: String) -> XCUIElement {
        ["Albums", "Artists", "Podcasts"].contains(name) ? outlines.buttons[name] : outlines.staticTexts[name]
    }

    /// The heading of the screen the main window shows.
    var routeTitle: XCUIElement {
        staticTexts["routeTitle"]
    }

    /// Waits for the main window to show the screen titled `title`.
    /// The saved albums, artists or podcasts grid; the now-playing bar can link the same names.
    var savedItems: XCUIElement { scrollViews["savedItems"] }

    func showsRoute(_ title: String) -> Bool {
        staticTexts.matching(NSPredicate(format: "identifier == 'routeTitle' AND value == %@", title)).firstMatch
            .waitForExistence(timeout: Self.timeout)
    }

    func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        menuBars.menuBarItems[menu].click()
        return menuBars.menuItems[item]
    }
}
