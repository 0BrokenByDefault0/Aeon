import XCTest

final class AdaptiveChromeTests: XCTestCase {
    func testCompactPortraitChromeKeepsEveryDestinationReachable() {
        let app = launch()
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        ensureNavigationVisible(in: app)
        for destination in ["sky", "library", "playlists", "settings"] {
            let button = app.buttons["aeon.navigation.\(destination)"]
            XCTAssertTrue(button.waitForExistence(timeout: 4))
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        app.buttons["aeon.navigation.library"].tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 4))
        ensureNavigationVisible(in: app)
        XCTAssertTrue(app.buttons["aeon.navigation.settings"].isHittable)
    }

    func testCompactLandscapePreservesSkyAndReachableLastDestination() {
        let app = launch()
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        XCUIDevice.shared.orientation = .landscapeLeft
        ensureNavigationVisible(in: app)
        let settings = app.buttons["aeon.navigation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.images["aeon.sky.canvas"].exists)
    }

    func testLargestAccessibilityTextDoesNotClipPrimaryNavigation() {
        let app = launch(accessibilityText: true)
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        ensureNavigationVisible(in: app)
        let playlists = app.buttons["aeon.navigation.playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 4))
        XCTAssertTrue(playlists.isHittable)
        playlists.tap()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 4))
    }

    private func launch(accessibilityText: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AeonSkyFixture", "small"]
        if accessibilityText {
            app.launchArguments.append("-AeonAX5Testing")
        }
        app.launch()
        return app
    }

    private func ensureNavigationVisible(in app: XCUIApplication) {
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 1), menu.label == "Open navigation" { menu.tap() }
    }
}
