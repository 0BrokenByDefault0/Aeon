import XCTest

final class SettingsFlowTests: XCTestCase {
    func testSettingsHierarchyCopyAndNativeControls() {
        let app = launch()
        openSettings(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.section.playback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.section.library"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.section.the-sky"].exists)
        let metadataCopy = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@",
            "Off by default. When enabled, missing album titles and artist names are sent to Apple and MusicBrainz"
        )).firstMatch
        scroll(in: app, until: app.descendants(matching: .any)["aeon.settings.metadata-lookups"])
        XCTAssertTrue(metadataCopy.exists)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.import-grouping"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.metadata-lookups"].exists)
        let hud = app.descendants(matching: .any)["aeon.settings.hud"]
        scroll(in: app, until: hud)
        XCTAssertTrue(hud.exists)
        XCTAssertTrue(hud.isHittable)
        XCTAssertEqual(hud.value as? String, "0")
        hud.tap()
        XCTAssertEqual(hud.value as? String, "1")
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.sky"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.hud"].waitForExistence(timeout: 5))
        openSettings(in: app)
        scroll(in: app, until: app.descendants(matching: .any)["aeon.settings.reduce-motion"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.sky-contrast"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.reduce-motion"].exists)
        XCTAssertFalse(app.buttons["Load Sample"].exists)
        XCTAssertFalse(app.buttons["Developer"].exists)

        scrollToBottom(in: app)
        XCTAssertTrue(app.buttons["aeon.settings.backup-full"].exists)
        XCTAssertTrue(app.buttons["aeon.settings.backup-catalog"].exists)
        XCTAssertTrue(app.buttons["aeon.settings.restore"].exists)
        XCTAssertTrue(app.buttons["aeon.settings.activity"].exists)
        XCTAssertTrue(app.buttons["aeon.settings.diagnostics"].exists)
        XCTAssertTrue(app.staticTexts["Albums, audio, playlists, and the log — the sky goes dark."].exists)
    }

    func testEqualizerAndSpectrumLinksOpenTheirNowPlayingSections() {
        let app = launch()
        openSettings(in: app)

        let eq = app.buttons["aeon.settings.eq.open"]
        scroll(in: app, until: eq)
        XCTAssertTrue(eq.waitForExistence(timeout: 5))
        eq.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.player.eq.bypass"].waitForExistence(timeout: 6))
        app.buttons["aeon.player.close"].tap()

        let spectrum = app.buttons["aeon.settings.spectrum.open"]
        scroll(in: app, until: spectrum)
        XCTAssertTrue(spectrum.waitForExistence(timeout: 5))
        spectrum.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.player.spectrum"].waitForExistence(timeout: 6))
    }

    func testPlaylistCreationAndTypedEraseGate() {
        let app = launch()
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.playlists"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.playlists.screen"].waitForExistence(timeout: 6))

        var nameField = app.textFields["aeon.playlists.name"]
        if !nameField.waitForExistence(timeout: 2) {
            app.buttons["aeon.playlists.create"].tap()
            nameField = app.textFields["aeon.playlists.name"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        }
        nameField.tap()
        nameField.typeText("Task Nineteen Route")
        let done = app.keyboards.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        done.tap()
        let route = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Task Nineteen Route")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        XCTAssertTrue(app.staticTexts["Empty route."].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["aeon.playlists.detail.delete"].exists)
        app.buttons["aeon.playlists.detail.close"].tap()

        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 5))
        scrollToBottom(in: app)
        app.buttons["aeon.settings.erase"].tap()
        let eraseCopy = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@",
            "This removes Aeon’s catalogue, artwork, playlists, listening history, and copied audio"
        )).firstMatch
        XCTAssertTrue(eraseCopy.waitForExistence(timeout: 4))
        let commit = app.buttons["Erase Everything"]
        XCTAssertTrue(commit.exists)
        XCTAssertFalse(commit.isEnabled)
        let confirmation = app.textFields["aeon.settings.erase-confirmation"]
        confirmation.tap()
        confirmation.typeText("ERAS")
        XCTAssertFalse(commit.isEnabled)
        confirmation.press(forDuration: 1)
        app.menuItems["Select All"].tap()
        confirmation.typeText("ERASE")
        XCTAssertTrue(commit.isEnabled)
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AeonPlaybackFixture", "loaded"]
        app.launch()
        return app
    }

    private func openSettings(in app: XCUIApplication) {
        openNavigationIfNeeded(in: app)
        let settings = app.buttons["aeon.navigation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 6))
    }

    private func openNavigationIfNeeded(in app: XCUIApplication) {
        if app.buttons["aeon.navigation.settings"].waitForExistence(timeout: 2) { return }
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 12), menu.label == "Open navigation" {
            menu.tap()
            XCTAssertEqual(menu.label, "Close navigation")
            XCTAssertTrue(app.buttons["aeon.navigation.settings"].waitForExistence(timeout: 3))
        }
    }

    private func scrollToBottom(in app: XCUIApplication) {
        let erase = app.buttons["aeon.settings.erase"]
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<12 where !isFullyVisible(erase, in: scrollView) {
            if scrollView.exists { scrollView.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(isFullyVisible(erase, in: scrollView))
    }

    private func isFullyVisible(_ element: XCUIElement, in scrollView: XCUIElement) -> Bool {
        guard element.exists, element.isHittable, scrollView.exists else { return false }
        return scrollView.frame.insetBy(dx: 1, dy: 1).contains(element.frame)
    }

    private func scroll(in app: XCUIApplication, until element: XCUIElement) {
        for _ in 0..<8 where !element.exists || !element.isHittable { app.swipeUp() }
    }
}
