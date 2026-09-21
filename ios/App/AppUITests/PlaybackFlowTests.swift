import XCTest

final class PlaybackFlowTests: XCTestCase {
    func testLoadedPausedTrackExposesPersistentPlayerAndCompleteSurface() {
        let app = launch()

        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["aeon.player.open"].isHittable)
        app.buttons["aeon.player.open"].tap()

        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["aeon.player.shuffle"].exists)
        XCTAssertTrue(app.buttons["aeon.player.repeat"].exists)
        XCTAssertTrue(app.buttons["aeon.player.queue.open"].exists)
        XCTAssertTrue(app.buttons["aeon.player.locate"].exists)
        let eqBypass = app.descendants(matching: .any)["aeon.player.eq.bypass"]
        scrollUp(in: app, until: eqBypass)
        XCTAssertTrue(eqBypass.exists)
        scrollUp(in: app, until: app.descendants(matching: .any)["aeon.player.spectrum"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.player.spectrum"].exists)
    }

    func testNowPlayingScrollStaysBelowHeaderAndAllTenEQBandsAreVisibleTogether() {
        let app = launch()
        openNowPlaying(in: app)
        let close = app.buttons["aeon.player.close"]
        let locate = app.buttons["aeon.player.locate"]
        scrollUntilHittable(locate, in: app)
        XCTAssertTrue(locate.isHittable)
        XCTAssertGreaterThanOrEqual(locate.frame.minY, close.frame.maxY)

        let bands = app.descendants(matching: .any)["aeon.player.eq.bands"]
        app.buttons["aeon.player.eq.open"].tap()
        XCTAssertTrue(bands.waitForExistence(timeout: 4))
        XCTAssertTrue(bands.isHittable)
        let frequencies = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        let controls = frequencies.map { app.descendants(matching: .any)["aeon.player.eq.band.\($0)"] }
        XCTAssertTrue(controls.allSatisfy(\.exists))
        XCTAssertTrue(controls.allSatisfy(\.isHittable))
        XCTAssertGreaterThanOrEqual(controls.first!.frame.minX, bands.frame.minX - 1)
        XCTAssertLessThanOrEqual(controls.last!.frame.maxX, bands.frame.maxX + 1)
    }

    func testQueueActionsKeepCurrentPinnedAndSaveInline() {
        let app = launch()
        openNowPlaying(in: app)
        app.buttons["aeon.player.queue.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.queue.close"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["aeon.player.queue.current"].exists)
        let handle = app.images["aeon.player.queue.drag.playback-fixture-track-2"]
        XCTAssertTrue(handle.exists)
        XCTAssertGreaterThanOrEqual(handle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(handle.frame.height, 44)

        app.buttons["aeon.player.queue.save"].tap()
        let name = app.textFields["aeon.player.queue.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Night Route")
        app.buttons["aeon.player.queue.commit-save"].tap()
        XCTAssertTrue(app.staticTexts["Saved “Night Route” with 3 tracks."].waitForExistence(timeout: 4))

        app.buttons["aeon.player.queue.clear"].tap()
        XCTAssertTrue(app.staticTexts["Upcoming tracks cleared. Current track keeps playing."].waitForExistence(timeout: 4))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "aeon.player.queue.current").count, 1)
    }

    func testLocateTakesTwoTapsFromAnotherDestinationAndRotationKeepsPlayerOpen() {
        let app = launch()
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 4))
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.locate"].waitForExistence(timeout: 4))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 4))
        XCUIDevice.shared.orientation = .portrait
        app.buttons["aeon.player.locate"].tap()

        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.star-selection"].waitForExistence(timeout: 5))
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AeonPlaybackFixture", "loaded"]
        app.launch()
        return app
    }

    private func openNowPlaying(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 6))
    }

    private func openNavigationIfNeeded(in app: XCUIApplication) {
        if app.buttons["aeon.navigation.settings"].waitForExistence(timeout: 2) { return }
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 12), menu.label == "Open navigation" { menu.tap() }
    }

    private func scrollUp(in app: XCUIApplication, until element: XCUIElement) {
        for _ in 0..<6 where !element.exists {
            app.swipeUp()
        }
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
    }
}
