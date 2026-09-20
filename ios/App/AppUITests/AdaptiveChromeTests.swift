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

extension AdaptiveChromeTests {
    @objc func testOrbitalUIReviewEmptyScreensAndControls() {
        var app = reviewLaunch(["-AeonSkyFixture", "empty"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 12))
        reviewCapture(app, name: "orbital-sky-empty")
        let importMusic = app.buttons["aeon.library.import"]
        assertHittable(importMusic, in: app)
        reviewCapture(importMusic, name: "orbital-primary-import-closeup")
        importMusic.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.import.sheet"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "aeon.library.import.files").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "aeon.library.import.adopt").count, 1)
        XCTAssertTrue(app.buttons["aeon.library.import.files"].isHittable)
        XCTAssertTrue(app.buttons["aeon.library.import.adopt"].isHittable)
        reviewCapture(app, name: "orbital-import-sheet")

        app.terminate()
        app = reviewLaunch(["-AeonSkyFixture", "empty"])
        ensureNavigationVisible(in: app)
        app.buttons["aeon.navigation.library"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.empty"].waitForExistence(timeout: 5))
        assertNoInactiveSky(in: app, importButtons: 1)
        reviewCapture(app, name: "orbital-library-empty")
        let libraryImport = app.buttons["aeon.library.import"]
        assertHittable(libraryImport, in: app)
        let emptyLibrary = app.descendants(matching: .any)["aeon.library.empty"]
        XCTAssertTrue(emptyLibrary.frame.contains(libraryImport.frame), "Empty Library must own a reachable primary action")
        reviewCapture(libraryImport, name: "polish-library-primary-closeup")
        libraryImport.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.import.sheet"].waitForExistence(timeout: 5))
        app.buttons["aeon.import.close"].tap()
        assertState(app.descendants(matching: .any)["aeon.import.sheet"], predicate: "exists == false")
        ensureNavigationVisible(in: app)
        app.buttons["aeon.navigation.playlists"].tap()
        assertState(app.descendants(matching: .any)["aeon.library.screen"], predicate: "exists == false")
        let create = app.buttons["aeon.playlists.create"]
        assertHittable(create, in: app)
        assertNoInactiveSky(in: app, importButtons: 0)
        reviewCapture(app, name: "orbital-playlists-empty")
        reviewCapture(create, name: "orbital-primary-playlist-closeup")
        ensureNavigationVisible(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        assertState(app.descendants(matching: .any)["aeon.playlists.screen"], predicate: "exists == false")
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 5))
        for value in ["off", "minutes15", "minutes30", "minutes60", "endOfAlbum"] {
            let option = app.buttons["aeon.settings.sleep.\(value)"]
            XCTAssertEqual(app.buttons.matching(identifier: option.identifier).count, 1)
            assertHittable(option, in: app)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(option.frame))
        }
        assertNoInactiveSky(in: app, importButtons: 0)
        reviewCapture(app, name: "orbital-settings")
        assertEqualSleepTargets(in: app)
        app.buttons["aeon.settings.sleep.minutes15"].tap()
        assertState(app.buttons["aeon.settings.sleep.minutes15"], predicate: "selected == true")
        let timer = app.descendants(matching: .any).matching(identifier: "aeon.settings.sleep.control").firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        reviewCapture(timer, name: "orbital-sleep-timer-closeup")
        let toggle = app.switches["aeon.settings.import-grouping"]
        reviewScroll(app, until: toggle)
        XCTAssertTrue(toggle.isHittable)
        let original = toggle.value as? String
        XCTAssertNotNil(original)
        reviewCapture(toggle, name: "orbital-toggle-before-closeup")
        toggle.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original ?? "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        reviewCapture(toggle, name: "orbital-toggle-after-closeup")
        toggle.tap()
        assertState(toggle, predicate: "value == '\(original ?? "1")'")
        ensureNavigationVisible(in: app)
        app.buttons["aeon.navigation.sky"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "aeon.library.import").count, 1)
        reviewCapture(app, name: "orbital-sky-return-after-tabs")
    }

    @objc func testOrbitalUIReviewSkyWithOneAlbum() {
        let app = reviewLaunch(["-AeonPlaybackFixture", "loaded"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        ensureNavigationVisible(in: app)
        app.buttons["aeon.navigation.library"].tap()
        let count = app.staticTexts["aeon.library.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1 ALBUM", "This capture must use one actual fixture album, not the 48-album small fixture")
        reviewCapture(app, name: "orbital-library-one-album")
        ensureNavigationVisible(in: app)
        app.buttons["aeon.navigation.sky"].tap()
        assertState(app.descendants(matching: .any)["aeon.library.screen"], predicate: "exists == false")
        XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.empty"].exists)
        reviewCapture(app, name: "orbital-sky-one-album")
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 5))
        reviewCapture(app, name: "orbital-now-playing-disc")
        let eq = app.switches["aeon.player.eq.bypass"]
        reviewScroll(app, until: eq)
        let originalEQ = eq.value as? String
        XCTAssertNotNil(originalEQ)
        eq.tap()
        let changedEQ = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", originalEQ ?? "0"), object: eq)
        XCTAssertEqual(XCTWaiter.wait(for: [changedEQ], timeout: 5), .completed)
        let bass = app.buttons["aeon.player.eq.preset.bass-ritual"]
        reviewScroll(app, until: bass)
        bass.tap()
        assertState(bass, predicate: "selected == true")
        let presets = app.descendants(matching: .any).matching(identifier: "aeon.player.eq.presets").firstMatch
        reviewCapture(presets, name: "orbital-eq-presets-closeup")
    }

    @objc func testOrbitalDockBoundsAfterAX5EmptyStateNavigation() {
        let app = reviewLaunch(["-AeonSkyFixture", "empty", "-AeonAX5Testing"])
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            ensureNavigationVisible(in: app)
            app.buttons["aeon.navigation.playlists"].tap()
            ensureNavigationVisible(in: app)
            app.buttons["aeon.navigation.settings"].tap()
            reviewScroll(app, until: app.buttons["aeon.settings.erase"])
            let activity = app.buttons["aeon.settings.activity"]
            if activity.isHittable {
                XCTAssertGreaterThanOrEqual(
                    activity.frame.minY,
                    app.statusBars.firstMatch.frame.maxY,
                    "Scrolled Settings controls must stay below system chrome"
                )
            }
            ensureNavigationVisible(in: app)
            for name in ["sky", "library", "playlists", "settings"] {
                let button = app.buttons["aeon.navigation.\(name)"]
                assertHittable(button, in: app)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame), "Out-of-window target: \(button.frame)")
            }
            assertNoInactiveSky(in: app, importButtons: 0)
            reviewCapture(app, name: "orbital-ax5-dock-\(orientation.isLandscape ? "landscape" : "portrait")")
        }
    }

    private func assertNoInactiveSky(in app: XCUIApplication, importButtons: Int) {
        assertState(app.descendants(matching: .any)["aeon.sky.empty"], predicate: "exists == false")
        XCTAssertFalse(app.staticTexts["Your sky is quiet"].exists)
        XCTAssertFalse(app.staticTexts["Bring your records. Aeon will chart them without changing the files you chose."].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "aeon.library.import").count, importButtons,
                       "Only the active screen's import action may exist")
        XCTAssertTrue(app.images["aeon.sky.canvas"].exists, "Preserve the renderer and camera, not inactive Sky controls")
    }

    private func reviewLaunch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AeonReduceMotionTesting"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 12))
        // CoreSimulator occasionally publishes a transient infinite accessibility
        // window immediately after a UI-test relaunch. The pixels are correct, but
        // every activation point is invalid until the AX bridge is re-established.
        // Retry only that infrastructure state; a finite app window still has to
        // satisfy every normal reachability assertion below.
        if !isUsableFrame(app.windows.firstMatch.frame) {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 12))
        }
        XCTAssertTrue(isUsableFrame(app.windows.firstMatch.frame), "Simulator did not publish a finite app window")
        XCTAssertEqual(app.webViews.count, 0)
        return app
    }
    private func reviewScroll(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 0..<24 where !element.exists || !element.isHittable {
            let vertical = app.scrollViews.allElementsBoundByIndex
                .filter { isUsableFrame($0.frame) }
                .max { lhs, rhs in lhs.frame.height < rhs.frame.height }
            guard let vertical else { break }
            // Drag near the trailing edge so seek, volume and horizontal EQ controls
            // cannot intercept the gesture intended for the long-form player.
            vertical.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.82))
                .press(forDuration: 0.01, thenDragTo: vertical.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.24)))
        }
        assertHittable(element, in: app)
    }
    private func isUsableFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
    private func reviewCapture(_ element: XCUIElement, name: String) {
        // Accessibility state can settle before a removal transition has finished drawing.
        // Allow the bounded chrome fade to complete before collecting visual evidence.
        Thread.sleep(forTimeInterval: 0.4)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension AdaptiveChromeTests {
    private func assertEqualSleepTargets(in app: XCUIApplication) {
        let options = ["off", "minutes15", "minutes30", "minutes60", "endOfAlbum"].map {
            app.buttons["aeon.settings.sleep.\($0)"]
        }
        let width = options[0].frame.width
        for (index, option) in options.enumerated() {
            assertHittable(option, in: app)
            XCTAssertGreaterThanOrEqual(option.frame.width, 44)
            XCTAssertGreaterThanOrEqual(option.frame.height, 44)
            XCTAssertEqual(option.frame.width, width, accuracy: 1)
            if index > 0 {
                XCTAssertLessThanOrEqual(options[index - 1].frame.maxX, option.frame.minX + 0.5,
                                        "Adjacent timer choices must not share touch regions")
            }
            for x in [0.15, 0.85] {
                options[(index + 1) % options.count].tap()
                option.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
                assertState(option, predicate: "selected == true")
                XCTAssertEqual(options.filter { $0.isSelected }.count, 1)
            }
        }
        options[0].tap()
    }
}
