import XCTest

/// The original defect was invisible to every unit test: three `fileImporter` modifiers
/// on one view left IMPORT FILES inert, so the button was live, the state flag flipped,
/// and nothing appeared. The redesigned shell adds one intentional import entry point,
/// then still asserts that the chosen source presents the real system picker.
final class ImportPickerPresentationTests: XCTestCase {
    func testImportFilesPresentsTheSystemDocumentPicker() {
        let app = launch()
        openImportSheet(in: app)
        let button = app.buttons["aeon.library.import.files"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(documentPickerIsPresented(over: app), "Files import opened no picker")
        dismissDocumentPicker(over: app)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 8))
    }

    func testImportFolderPresentsTheSystemDocumentPicker() {
        let app = launch()
        openImportSheet(in: app)
        let button = app.buttons["aeon.library.import.folder"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(documentPickerIsPresented(over: app), "Folder import opened no picker")
        dismissDocumentPicker(over: app)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 8))
    }

    func testCancellingAPickerLeavesNoImportErrorBehind() {
        let app = launch()
        openImportSheet(in: app)
        let button = app.buttons["aeon.library.import.files"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(documentPickerIsPresented(over: app))
        dismissDocumentPicker(over: app)

        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.import.error"].exists)
        XCTAssertFalse(app.alerts.element.exists)
    }

    private func openImportSheet(in app: XCUIApplication) {
        let primary = app.buttons["aeon.library.import"]
        XCTAssertTrue(primary.waitForExistence(timeout: 12))
        primary.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.import.sheet"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["aeon.import.sheet"].exists,
            "The sheet identifier must not replace an import source identifier."
        )
        for identifier in ["aeon.library.import.files", "aeon.library.import.folder"] {
            let sources = app.buttons.matching(identifier: identifier)
            XCTAssertTrue(sources.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(sources.count, 1, "Each import source must have a unique identifier.")
        }
    }

    /// The picker is a remote view controller, so it may surface either inside Aeon's own
    /// element tree or as the document manager's process. Accept either, and treat only
    /// "neither ever appeared" as a failure.
    private func documentPickerIsPresented(over app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if cancelButton(over: app) != nil { return true }
            if app.navigationBars.count > 0 { return true }
            _ = app.buttons.firstMatch.waitForExistence(timeout: 1)
        }
        return false
    }

    private func cancelButton(over app: XCUIApplication) -> XCUIElement? {
        for candidate in [app, documentManager] {
            let cancel = candidate.buttons["Cancel"]
            if cancel.exists, cancel.isHittable { return cancel }
        }
        return nil
    }

    private func dismissDocumentPicker(over app: XCUIApplication) {
        if let cancel = cancelButton(over: app) {
            cancel.tap()
            return
        }
        app.swipeDown()
    }

    private var documentManager: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore")
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        return app
    }
}

extension ImportPickerPresentationTests {
    /// Only a source WAV is generated. No delegate call, catalogue insertion or import
    /// invocation is injected: Apple Files must deliver the directory after Open.
    @objc func testFolderOpenImportsNestedAudioThroughSystemPicker() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AeonSkyFixture", "empty", "-AeonFolderPickerAcceptance", "-AeonReduceMotionTesting"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 12))
        openImportSheet(in: app)
        app.buttons["aeon.library.import.folder"].tap()

        let child = waitForFolderElement(over: app, labels: ["Nested Record"], button: false)
        XCTAssertNotNil(child, "The system browser must be inside the actual generated source directory")
        let open = try XCTUnwrap(waitForFolderElement(over: app, labels: ["Open", "Done"], button: true),
                                 "The system folder picker must expose its real confirmation button")
        XCTAssertTrue(open.isEnabled)
        attachFolderEvidence(app, name: "folder-selected-before-system-open")
        open.tap()

        let notice = app.alerts["Import"]
        guard notice.waitForExistence(timeout: 30) else {
            attachFolderEvidence(app, name: "folder-open-missing-result")
            return XCTFail("Folder Open did not reach the real importer and produce a result")
        }
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Added 1 track in 1 album to Library."
        )).firstMatch.exists, notice.debugDescription)
        attachFolderEvidence(app, name: "folder-open-import-result")
        notice.buttons["OK"].tap()
        let count = app.staticTexts["aeon.library.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        XCTAssertEqual(count.label, "1 ALBUM")
        let album = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "aeon.library.album."
        )).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        album.tap()
        let track = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "aeon.album.track."
        )).firstMatch
        for _ in 0..<8 where !track.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(track.waitForExistence(timeout: 5), "Nested audio must become an actual catalogue track")
        attachFolderEvidence(app, name: "folder-open-catalogue-track")
    }

    private func waitForFolderElement(over app: XCUIApplication, labels: [String], button: Bool) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(20)
        let predicate = NSPredicate(format: "label IN %@", labels)
        while Date() < deadline {
            // The remote Files UI is surfaced in the host app's accessibility tree on
            // current simulators. Querying a separate non-running DocumentManager
            // process aborts XCTest before the actual folder interaction is exercised.
            let query = button ? app.buttons.matching(predicate) : app.descendants(matching: .any).matching(predicate)
            if let element = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return element }
            Thread.sleep(forTimeInterval: 0.25)
        }
        attachFolderEvidence(app, name: button ? "folder-open-button-missing" : "folder-source-missing")
        return nil
    }

    private func attachFolderEvidence(_ app: XCUIApplication, name: String) {
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = name; picture.lifetime = .keepAlways; add(picture)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
