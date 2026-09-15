import XCTest

/// The player panel sits above Aeon's own navigation chrome, so once it is open the
/// only way back must come from the panel itself. An empty player used to render
/// without a heading, leaving the host app's system back indicator as the sole exit.
final class PlayerNavigationTests: XCTestCase {
    func testEmptyPlayerCanBeLeftWithoutTheHostAppsBackIndicator() {
        let app = launch()
        openEmptyPlayer(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["aeon.player.empty"].exists)
        let close = app.buttons["aeon.player.close"]
        XCTAssertTrue(close.exists)
        XCTAssertTrue(close.isHittable)
        close.tap()

        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.descendants(matching: .any)["aeon.player.empty"].exists)
    }

    func testEmptyPlayerAlsoOffersALabelledWayBackInItsBody() {
        let app = launch()
        openEmptyPlayer(in: app)

        let back = app.buttons["BACK TO AEON"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        XCTAssertTrue(back.isHittable)
        back.tap()

        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 6))
    }

    private func openEmptyPlayer(in app: XCUIApplication) {
        openNavigationIfNeeded(in: app)
        let settings = app.buttons["aeon.navigation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 6))

        let eq = app.buttons["aeon.settings.eq.open"]
        for _ in 0..<8 where !eq.exists || !eq.isHittable { app.swipeUp() }
        XCTAssertTrue(eq.waitForExistence(timeout: 5))
        eq.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.player.empty"].waitForExistence(timeout: 6))
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func openNavigationIfNeeded(in app: XCUIApplication) {
        if app.buttons["aeon.navigation.settings"].waitForExistence(timeout: 2) { return }
        let menu = app.buttons["aeon.navigation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 12))
        menu.tap()
        XCTAssertTrue(app.buttons["aeon.navigation.settings"].waitForExistence(timeout: 6))
    }
}
