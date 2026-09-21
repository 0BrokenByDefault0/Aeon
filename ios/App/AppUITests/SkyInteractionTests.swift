import XCTest

final class SkyInteractionTests: XCTestCase {
    func testOceanWorldRenderedSelection() { captureWorld(0) }
    func testStormWorldRenderedSelection() { captureWorld(1) }
    func testGlacialWorldRenderedSelection() { captureWorld(2) }
    func testVolcanicWorldRenderedSelection() { captureWorld(3) }
    func testRingedWorldRenderedSelection() { captureWorld(4) }
    func testAuroralWorldRenderedSelection() { captureWorld(5) }

    private func captureWorld(_ index: Int) {
        let app = launch(fixture: "world-family-\(index)")
        let canvas = app.descendants(matching: .any)["aeon.sky.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 12))
        XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.planet-selection"].exists)
        let unselected = XCTAttachment(screenshot: app.screenshot())
        unselected.name = "world-family-\(index)-unselected-simulator"
        unselected.lifetime = .keepAlways
        add(unselected)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.planet-selection"].waitForExistence(timeout: 3))
        let selected = XCTAttachment(screenshot: app.screenshot())
        selected.name = "world-family-\(index)-selected-simulator"
        selected.lifetime = .keepAlways
        add(selected)
        // Clear in empty sky; the large ring/glow envelope must not capture this.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.planet-selection"].exists)
    }

    func testSmallSkyLaunchesAndCameraAcceptsPanAndPinch() {
        let app = launch(fixture: "small")
        let canvas = app.descendants(matching: .any)["aeon.sky.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 12))
        XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.hud"].exists)
        canvas.swipeLeft()
        canvas.pinch(withScale: 1.8, velocity: 1.2)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.altitude"].exists)
        XCTAssertTrue(app.buttons["aeon.sky.capture"].exists)
    }

    func testPlanetSelectedFixtureShowsEraSelectionAndTracesRemainInteractive() {
        let app = launch(fixture: "planet-selected")
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.canvas"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.planet-selection"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["aeon.sky.canvas"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.altitude"].exists)
    }

    func testEmptyAndUnchartedFixturesAreDeterministic() {
        let empty = launch(fixture: "empty")
        XCTAssertTrue(empty.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 12))
        empty.terminate()
        let uncharted = launch(fixture: "uncharted")
        XCTAssertTrue(uncharted.descendants(matching: .any)["aeon.sky.canvas"].waitForExistence(timeout: 12))
        XCTAssertFalse(uncharted.descendants(matching: .any)["aeon.sky.empty"].exists)
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AeonSkyFixture", fixture]
        app.launch()
        return app
    }
}
