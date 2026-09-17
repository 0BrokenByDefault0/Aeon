import XCTest
import UIKit

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

    func testPrimaryNavigationRespondsAcrossItsFullTargets() {
        assertFullNavigationTargets(accessibilityText: false)
    }

    func testLargestAccessibilityNavigationRespondsAcrossItsFullTargets() {
        assertFullNavigationTargets(accessibilityText: true)
    }

    private func assertFullNavigationTargets(accessibilityText: Bool) {
        let app = launch(accessibilityText: accessibilityText)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))

        // Regular-width portrait uses a menu; compact widths expose the dock directly.
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.exists {
            assertHittable(menu, in: app)
            XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
            XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
            XCTAssertEqual(menu.label, "Open navigation")
            tapPaddedCorner(of: menu)
            assertState(menu, predicate: "label == 'Close navigation'")
            assertHittable(app.buttons["aeon.navigation.sky"], in: app)
            tapPaddedCorner(of: menu)
            assertState(menu, predicate: "label == 'Open navigation'")
        }

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for destination in ["library", "playlists", "settings", "sky"] {
                ensureNavigationVisible(in: app)
                let button = app.buttons["aeon.navigation.\(destination)"]
                assertHittable(button, in: app)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                // A center tap can hit the glyph even when its surrounding target is inert.
                tapPaddedCorner(of: button)
                if destination == "sky" {
                    assertState(app.descendants(matching: .any)["aeon.settings.screen"], predicate: "exists == false")
                    XCTAssertTrue(app.images["aeon.sky.canvas"].exists)
                } else {
                    XCTAssertTrue(app.descendants(matching: .any)["aeon.\(destination).screen"].waitForExistence(timeout: 5))
                }
                ensureNavigationVisible(in: app)
                assertState(app.buttons["aeon.navigation.\(destination)"], predicate: "selected == true")
            }
        }
    }

    private func tapPaddedCorner(of element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 6, dy: 6))
            .tap()
    }

    private func assertState(_ element: XCUIElement, predicate: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Navigation state did not settle: \(element.identifier), \(predicate)")
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
