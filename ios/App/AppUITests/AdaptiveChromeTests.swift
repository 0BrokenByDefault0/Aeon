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
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.screen"].waitForExistence(timeout: 4))
        ensureNavigationVisible(in: app)
        assertHittable(app.buttons["aeon.navigation.settings"], in: app)
    }

    func testCompactLandscapePreservesSkyAndReachableLastDestination() {
        let app = launch()
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        XCUIDevice.shared.orientation = .landscapeLeft
        ensureNavigationVisible(in: app)
        let settings = app.buttons["aeon.navigation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        assertHittable(settings, in: app)
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.images["aeon.sky.canvas"].exists)
    }

    func testLargestAccessibilityTextDoesNotClipPrimaryNavigation() {
        let app = launch(accessibilityText: true)
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        ensureNavigationVisible(in: app)
        let playlists = app.buttons["aeon.navigation.playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 4))
        assertHittable(playlists, in: app)
        playlists.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.playlists.screen"].waitForExistence(timeout: 4))
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
        let destination = app.buttons["aeon.navigation.sky"]
        if destination.exists && destination.isHittable { return }
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 5), menu.label == "Open navigation" { menu.tap() }
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        assertHittable(destination, in: app)
    }

    private func assertHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "adaptive-chrome-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "adaptive-chrome-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("Unreachable \(element.identifier); target=\(element.frame), windows=\(app.windows.allElementsBoundByIndex.map(\.frame))")
            return
        }
    }
}
