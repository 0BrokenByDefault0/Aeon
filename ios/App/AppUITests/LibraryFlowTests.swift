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
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        album.tap()
        XCTAssertTrue(app.buttons["aeon.album.play"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["aeon.album.find-in-sky"].exists)
        app.buttons["aeon.album.edit"].tap()
        let title = app.textFields["aeon.album.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.press(forDuration: 1)
        app.menuItems["Select All"].tap()
        title.typeText("Glass Archive Revised")
        app.buttons["aeon.album.editor.save"].tap()
        XCTAssertTrue(app.staticTexts["Glass Archive Revised"].waitForExistence(timeout: 6))
        app.buttons["aeon.album.find-in-sky"].tap()
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.star-selection"].waitForExistence(timeout: 6))
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
