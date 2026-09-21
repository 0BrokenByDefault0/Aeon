import XCTest

final class LibraryFlowTests: XCTestCase {
    func testEmptyFirstRunHasOneImportPathAndNoWebControls() {
        let app = launch(fixture: "empty")
        openLibrary(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.empty"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["aeon.library.import"].exists)
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testPopulatedLibrarySearchSeparatesTrackResultsAndKeepsControlsReachable() {
        let app = launch(fixture: "populated")
        openLibrary(in: app)
        XCTAssertTrue(app.staticTexts["12 ALBUMS"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["aeon.library.sort.played"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["aeon.library.density.list"].frame.width, 44)
        let search = app.textFields["aeon.library.search"]
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText("Silver Chamber")
        XCTAssertTrue(app.buttons["aeon.library.search.track.library-fixture-album-12-track-2"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["aeon.library.search.album.library-fixture-album-12"].exists)
    }

    func testAlbumDetailEditAndFindInSkyUseTheExactAlbum() {
        let app = launch(fixture: "populated")
        openLibrary(in: app)
        let album = app.buttons["aeon.library.album.library-fixture-album-12"]
        guard album.waitForExistence(timeout: 8) else {
            fail("Fixture album did not appear", in: app)
            return
        }
        album.tap()
        XCTAssertTrue(app.buttons["aeon.album.play"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["aeon.album.find-in-sky"].exists)
        app.buttons["aeon.album.actions"].tap()
        XCTAssertTrue(app.buttons["aeon.album.edit"].waitForExistence(timeout: 3))
        app.buttons["aeon.album.edit"].tap()
        let title = app.textFields["aeon.album.editor.title"]
        guard title.waitForExistence(timeout: 5) else {
            fail("Editor did not open", in: app)
            return
        }
        title.tap()
        guard let originalTitle = title.value as? String, originalTitle == "Glass Archive" else {
            fail("The editor did not load the original fixture title", in: app)
            return
        }
        let renamedTitle = "Glass Archive Revised"
        // The short fixture title ends before the field's tap point. Replace it
        // through the keyboard rather than depending on a transient Select All menu.
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalTitle.count) + renamedTitle)
        guard title.value as? String == renamedTitle else {
            fail("Title entry failed before Save; actual value: \(String(describing: title.value))", in: app)
            return
        }

        let save = app.buttons["aeon.album.editor.save"]
        guard reveal(save, in: app), save.isEnabled else {
            fail("Save is not reachable and enabled", in: app)
            return
        }
        save.tap()

        // A background detail remains in the accessibility tree while a sheet is
        // presented. Its existence is not evidence that the editor dismissed.
        guard wait(for: title, predicate: "exists == false") else {
            let saveError = app.staticTexts["aeon.album.editor.save-error"]
            fail("Editor remained open after Save. Error: \(saveError.exists ? saveError.label : "none exposed")", in: app)
            return
        }
        let detailTitle = app.staticTexts["aeon.album.title"]
        guard wait(for: detailTitle, predicate: "label == %@", value: renamedTitle) else {
            fail("Editor dismissed, but the detail title did not update", in: app)
            return
        }

        // Reopen the same catalog ID so this also exercises a fresh repository read,
        // rather than accepting the editor's in-memory draft as proof of persistence.
        app.buttons["aeon.album.close"].tap()
        guard album.waitForExistence(timeout: 6) else {
            fail("Library album did not reappear after closing detail", in: app)
            return
        }
        guard reveal(album, in: app) else { return }
        album.tap()
        guard wait(for: detailTitle, predicate: "label == %@", value: renamedTitle) else {
            fail("The renamed title was not retained when reopening the same album", in: app)
            return
        }
        let findInSky = app.buttons["aeon.album.find-in-sky"]
        guard reveal(findInSky, in: app) else { return }
        findInSky.tap()
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.star-selection"].waitForExistence(timeout: 6))
    }

    private func wait(for element: XCUIElement, predicate: String, value: String? = nil) -> Bool {
        let condition = value.map { NSPredicate(format: predicate, $0) } ?? NSPredicate(format: predicate)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: condition, object: element)],
            timeout: 6
        ) == .completed
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.exists && element.isHittable { return true }
        let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
        guard scroll.exists else {
            fail("No owning scroll view for \(element.identifier)", in: app)
            return false
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return true }
            scroll.swipeUp()
        }
        guard element.exists && element.isHittable else {
            fail("Unreachable \(element.identifier); target=\(element.frame), scroll=\(scroll.frame)", in: app)
            return false
        }
        return true
    }

    private func fail(_ message: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "album-edit-failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "album-edit-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(message)
    }

    private func launch(fixture: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AeonLibraryFixture", fixture]
        app.launch()
        return app
    }

    private func openLibrary(in app: XCUIApplication) {
        let button = app.buttons["aeon.navigation.library"]
        if button.waitForExistence(timeout: 2) {
            button.tap()
            XCTAssertTrue(app.descendants(matching: .any)["aeon.library.screen"].waitForExistence(timeout: 8))
            return
        }
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 12), menu.label == "Open navigation" {
            menu.tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 12))
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.screen"].waitForExistence(timeout: 8))
    }
}
