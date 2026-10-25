import XCTest

/// Mirrors Veya's `UITestScenario`; an unknown name crashes the app at launch.
enum Scenario: String {
    case signedOut
    case signInCancelled
    case signInFails
    case signedIn
    case restoreFails
    case reconnecting
    case notPremium
    case largeLibrary
    case emptyLibrary
    case libraryFails
    case recentlyPlayedNeedsSignIn
    case webAPINotConnected
    case connectDevices
    case localNetworkDenied
    case remoteControl
    case playlistConflict
    case localFiles
    case crashedLastTime
    case restoredPlayback
}

@MainActor
extension XCUIApplication {
    static let timeout: TimeInterval = 5

    /// Launches Veya against in-memory fakes; it never reaches Spotify or the Keychain.
    /// `locale` ("pl_PL") runs the app in that language and region's formats instead of the Mac's.
    /// `windowWidth` sizes the main window; below the window minimum (930 pt) AppKit holds it there.
    static func launch(_ scenario: Scenario, locale: String? = nil, windowWidth: Int = 1200) -> XCUIApplication {
        let app = configured(scenario, locale: locale, windowWidth: windowWidth)
        app.launch()
        return app
    }

    /// As `launch`, for a caller that launches the app itself, such as a launch metric.
    static func configured(_ scenario: Scenario, locale: String? = nil, windowWidth: Int = 1200) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VEYA_UI_TEST_SCENARIO"] = scenario.rawValue
        if let locale, let language = locale.split(separator: "_").first {
            app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // The suite is written against the Dark appearance; a runner left on Light fails the contrast audits.
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        // Tests share the app's defaults, so pin the main window over any frame a user saved; AppKit fits it to the screen.
        app.launchArguments += ["-NSWindow Frame main", "0 0 \(windowWidth) 2000"]
        return app
    }

    var signInScreen: XCUIElement {
        staticTexts["Welcome to Veya"]
    }

    var signedInScreen: XCUIElement {
        outlines.staticTexts["Liked Songs"]
    }

    /// A sidebar row by name; "Albums", "Artists" and "Podcasts" are section headers that open the full page.
    func sidebarItem(_ name: String) -> XCUIElement {
        ["Albums", "Artists", "Podcasts"].contains(name) ? outlines.buttons[name] : outlines.staticTexts[name]
    }

    /// The toolbar's search field.
    var searchField: XCUIElement {
        textFields["searchField"]
    }

    /// The track list on Liked Songs, a playlist or an album.
    var trackList: XCUIElement {
        outlines["trackList"]
    }

    /// The heading of the screen the main window shows.
    var routeTitle: XCUIElement {
        staticTexts["routeTitle"]
    }

    /// Waits for the main window to show the screen titled `title`.
    /// The saved albums, artists or podcasts grid; the now-playing bar can link the same names.
    var savedItems: XCUIElement {
        scrollViews["savedItems"]
    }

    func showsRoute(_ title: String) -> Bool {
        staticTexts.matching(NSPredicate(format: "identifier == 'routeTitle' AND value == %@", title)).firstMatch
            .waitForExistence(timeout: Self.timeout)
    }

    /// Grouped forms draw a toggle as a switch or a checkbox depending on the macOS version.
    func toggle(_ label: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.checkBox, .switch].map(\.rawValue)
        return descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND label BEGINSWITH %@", types, label)).firstMatch
    }

    func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        menuBars.menuBarItems[menu].click()
        return menuBars.menuItems[item]
    }
}
