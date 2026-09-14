import XCTest

final class SkyInteractionTests: XCTestCase {
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
