import XCTest

final class AeonAccessibilityTests: XCTestCase {
    func testNativeRootAndEveryVisibleDestinationExposeSemanticControls() {
        let app = launch([
            "-AeonLibraryFixture", "populated",
            "-AeonAccessibilityTesting"
        ])

        XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 12))
        XCTAssertEqual(app.webViews.count, 0)
        openNavigationIfNeeded(in: app)
        let destinations = ["sky", "library", "playlists", "settings"]
        XCTAssertEqual(
            destinations.compactMap { app.buttons["aeon.navigation.\($0)"].label.lowercased() },
            destinations
        )
        for destination in destinations {
            assertMinimumTarget(app.buttons["aeon.navigation.\(destination)"])
        }

        app.buttons["aeon.navigation.library"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.screen"].waitForExistence(timeout: 6))
        let album = app.buttons["aeon.library.album.library-fixture-album-12"]
        scroll(in: app, until: album)
        album.tap()
        XCTAssertTrue(app.buttons["aeon.album.close"].waitForExistence(timeout: 6))
        for id in ["aeon.album.close", "aeon.album.actions", "aeon.album.play", "aeon.album.find-in-sky"] {
            assertMinimumTarget(app.descendants(matching: .any)[id])
        }
        app.buttons["aeon.album.actions"].tap()
        XCTAssertTrue(app.buttons["aeon.album.edit"].waitForExistence(timeout: 3))
        app.buttons["aeon.album.edit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.album.editor"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["aeon.album.editor.title"].label.isEmpty)
        let cancel = app.buttons["aeon.album.editor.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertEqual(cancel.label, "Cancel editing")
        assertMinimumTarget(cancel)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["aeon.album.editor.title"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        app.buttons["aeon.album.close"].tap()

        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.playlists"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.playlists.screen"].waitForExistence(timeout: 5))
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testSkyTraversalIsRegionThenConstellationThenAlbumWithSelectedPlanetState() throws {
        var app = launch(["-AeonSkyFixture", "small", "-AeonAccessibilityTesting"])
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))

        let regions = elements(in: app, prefix: "aeon.sky.accessibility.region.")
        let constellations = elements(in: app, prefix: "aeon.sky.accessibility.constellation.")
        let stars = elements(in: app, prefix: "aeon.sky.accessibility.star.")
        XCTAssertFalse(regions.isEmpty)
        XCTAssertFalse(constellations.isEmpty)
        XCTAssertEqual(stars.count, 48)
        XCTAssertFalse(regions[0].label.isEmpty)
        XCTAssertEqual(constellations[0].elementType, .button)
        XCTAssertTrue(stars[0].label.contains("Artist"))
        XCTAssertTrue(stars[0].label.contains("in "))
        assertMinimumTarget(regions[0])
        assertMinimumTarget(constellations[0])
        assertMinimumTarget(stars[0])

        let ordered = app.descendants(matching: .any).allElementsBoundByIndex.map(\.identifier)
        let firstRegion = ordered.firstIndex(where: { $0.hasPrefix("aeon.sky.accessibility.region.") })
        let firstConstellation = ordered.firstIndex(where: { $0.hasPrefix("aeon.sky.accessibility.constellation.") })
        let firstStar = ordered.firstIndex(where: { $0.hasPrefix("aeon.sky.accessibility.star.") })
        XCTAssertLessThan(try XCTUnwrap(firstRegion), try XCTUnwrap(firstConstellation))
        XCTAssertLessThan(try XCTUnwrap(firstConstellation), try XCTUnwrap(firstStar))

        app.terminate()
        app = launch(["-AeonSkyFixture", "planet-selected", "-AeonAccessibilityTesting"])
        let planet = app.descendants(matching: .any)["aeon.sky.accessibility.planet.planet:1"]
        XCTAssertTrue(planet.waitForExistence(timeout: 12))
        XCTAssertEqual(planet.elementType, .button)
        XCTAssertTrue(planet.isSelected)
        assertMinimumTarget(planet)
    }

    func testHUDUsesAnnouncementsAndTextInsteadOfColorAlone() {
        let app = launch(["-AeonSkyFixture", "small", "-AeonAccessibilityTesting"])
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        let hudToggle = app.descendants(matching: .any)["aeon.settings.hud"]
        scroll(in: app, until: hudToggle)
        XCTAssertTrue(["0", "Off"].contains(hudToggle.value as? String ?? ""))
        hudToggle.tap()
        XCTAssertTrue(["1", "On"].contains(hudToggle.value as? String ?? ""))
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.sky"].tap()
        let hud = app.descendants(matching: .any)["aeon.sky.hud"]
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertTrue(hud.label.localizedCaseInsensitiveContains("albums adrift"))
    }

    func testPlaybackStatesUseTextInsteadOfColorAlone() {
        let app = launch(["-AeonPlaybackFixture", "loaded"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.staticTexts["PAUSED"].waitForExistence(timeout: 5))
        let transport = app.buttons["aeon.player.primary-toggle"]
        XCTAssertEqual(transport.label, "Play")
        assertMinimumTarget(transport)
        transport.tap()
        XCTAssertTrue(app.staticTexts["PLAYING"].waitForExistence(timeout: 5))
        XCTAssertEqual(transport.label, "Pause")
    }

    func testPlaybackErrorExplainsRecoveryWithoutColorAlone() {
        let app = launch(["-AeonPlaybackFixture", "error"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        let failure = app.buttons["aeon.player.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.label.localizedCaseInsensitiveContains("could not be decoded"))
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func openNavigationIfNeeded(in app: XCUIApplication) {
        if app.buttons["aeon.navigation.sky"].waitForExistence(timeout: 2) { return }
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 10), menu.label == "Open navigation" { menu.tap() }
        XCTAssertTrue(app.buttons["aeon.navigation.sky"].waitForExistence(timeout: 4))
    }

    private func elements(in app: XCUIApplication, prefix: String) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
    }

    private func assertMinimumTarget(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Frames come back through a coordinate-space conversion, so a target authored
        // as exactly 44 points reports as 43.99999999999994. The tolerance absorbs that
        // rounding and nothing else: a genuinely undersized target still fails.
        let minimum: CGFloat = 44
        let tolerance: CGFloat = 0.01
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, minimum - tolerance, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, minimum - tolerance, file: file, line: line)
    }

    private func scroll(in app: XCUIApplication, until element: XCUIElement) {
        if element.exists && element.isHittable { return }
        let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
        guard scroll.exists else {
            recordScrollFailure("No owning scroll view for \(element.identifier)", in: app)
            return
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp()
        }
        guard element.exists && element.isHittable else {
            recordScrollFailure("Unreachable \(element.identifier); target=\(element.frame), scroll=\(scroll.frame)", in: app)
            return
        }
    }

    private func recordScrollFailure(_ message: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "accessibility-scroll-failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "accessibility-scroll-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(message)
    }
}
