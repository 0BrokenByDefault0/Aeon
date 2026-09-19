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

    func testAdoptLibraryScansAppOwnedMusicWithoutOpeningAnotherPicker() {
        let app = launch()
        openImportSheet(in: app)
        let button = app.buttons["aeon.library.import.adopt"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        let notice = app.alerts["Import"]
        XCTAssertTrue(notice.waitForExistence(timeout: 12), "Adopt Library should complete through Aeon's own Music folder")
        XCTAssertTrue(
            notice.staticTexts.matching(NSPredicate(
                format: "label CONTAINS[c] %@", "On My iPhone"
            )).firstMatch.exists,
            notice.debugDescription
        )
        XCTAssertFalse(app.buttons["Cancel"].exists, "Adopt Library must not request an external folder grant")
        notice.buttons["OK"].tap()
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
        for identifier in ["aeon.library.import.files", "aeon.library.import.adopt"] {
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
