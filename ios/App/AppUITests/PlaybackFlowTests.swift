import XCTest

final class PlaybackFlowTests: XCTestCase {
    func testSongMenuCreatesPlaylistAndMiniPlayerSurvivesSheetsAndTabs() {
        let app = launch()
        openNowPlaying(in: app)
        let actions = app.buttons["aeon.track.actions.playback-fixture-track-1"]
        XCTAssertTrue(actions.waitForExistence(timeout: 4))
        scrollUntilHittable(actions, in: app)
        actions.tap()
        app.buttons["ADD TO PLAYLIST"].tap()
        let name = app.textFields["aeon.track.playlist.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        assertSingleReachableMiniPlayer(in: app)
        name.tap()
        name.typeText("Quick Add")
        app.buttons["aeon.track.playlist.create"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 4))
        actions.tap()
        app.buttons["SHOW ALBUM"].tap()
        XCTAssertTrue(app.buttons["aeon.track.actions.playback-fixture-track-2"].waitForExistence(timeout: 4))
        // The album and a nested track sheet must both own a single reachable bar.
        assertSingleReachableMiniPlayer(in: app)
        let albumActions = app.buttons["aeon.track.actions.playback-fixture-track-2"]
        scrollUntilHittable(albumActions, in: app)
        albumActions.tap()
        app.buttons["ADD TO PLAYLIST"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        let mini = assertSingleReachableMiniPlayer(in: app)
        capture("Nested playlist sheet with its mini-player — simulator", in: app)
        mini.tap()
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 4))
        assertSingleReachableMiniPlayer(in: app)
        XCTAssertFalse(name.exists)
        let queue = app.buttons["aeon.player.queue.open"]
        scrollUntilHittable(queue, in: app)
        queue.tap()
        let closeQueue = app.buttons["aeon.player.queue.close"]
        XCTAssertTrue(closeQueue.waitForExistence(timeout: 4))
        assertSingleReachableMiniPlayer(in: app)
        closeQueue.tap()
        assertSingleReachableMiniPlayer(in: app)
        for destination in ["playlists", "settings", "library", "sky"] {
            app.buttons["aeon.navigation.\(destination)"].tap()
            let mini = assertSingleReachableMiniPlayer(in: app)
            XCTAssertTrue(mini.label.contains("A Signal Carried Across the Quiet"))
            if destination == "playlists" { XCTAssertTrue(app.staticTexts["Quick Add"].waitForExistence(timeout: 4)) }
        }
        capture("Translucent mini-player over Sky — simulator", in: app)
    }

    @discardableResult
    private func assertSingleReachableMiniPlayer(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let players = app.buttons.matching(identifier: "aeon.player.open")
        let ready = NSPredicate { _, _ in players.count == 1 && players.element.isHittable }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected exactly one reachable mini-player; found \(players.count)", file: file, line: line)
        XCTAssertEqual(players.count, 1, file: file, line: line)
        return players.element
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBundledCorrectionRequiresExactSelectionAndPreviewBeforeApplying() {
        let app = launch()
        openNowPlaying(in: app)
        app.buttons["aeon.player.eq.open"].tap()
        let disclosure = app.buttons["Device correction & gain"]
        scrollUntilHittable(disclosure, in: app)
        disclosure.tap()
        let help = app.staticTexts["aeon.correction.choose-first"]
        scrollUntilHittable(help, in: app)
        XCTAssertTrue(help.exists)
        let choose = app.buttons["aeon.correction.choose"]
        scrollUntilHittable(choose, in: app)
        choose.tap()
        let search = app.textFields["aeon.correction.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        assertSingleReachableMiniPlayer(in: app)
        search.tap()
        search.typeText("HD600")
        let profile = app.buttons["aeon.correction.profile.opra-sennheiser-hd600-oratory1990-harman-v1"]
        XCTAssertTrue(profile.waitForExistence(timeout: 4))
        profile.tap()
        let apply = app.buttons["aeon.correction.apply"]
        scrollUntilHittable(apply, in: app)
        XCTAssertTrue(help.exists, "Preview must not activate correction")
        apply.tap()
        let toggle = app.switches["aeon.correction.enabled"]
        // Return to the top of the expanded correction section.
        for _ in 0..<6 where !toggle.isHittable { app.swipeDown() }
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }

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
