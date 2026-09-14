import XCTest

/// The original defect was invisible to every unit test: three `fileImporter` modifiers
/// on one view left IMPORT FILES inert, so the button was live, the state flag flipped,
/// and nothing appeared. Only driving the real UI catches that, so these tests assert
/// that a system document picker actually comes up and can be dismissed again.
final class ImportPickerPresentationTests: XCTestCase {
    func testImportFilesPresentsTheSystemDocumentPicker() {
        let app = launch()
        let button = app.buttons["aeon.library.import.files"]
        XCTAssertTrue(button.waitForExistence(timeout: 12))
        button.tap()

        XCTAssertTrue(documentPickerIsPresented(over: app), "IMPORT FILES opened no picker")
        dismissDocumentPicker(over: app)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 8))
    }

    func testImportFolderPresentsTheSystemDocumentPicker() {
        let app = launch()
        let button = app.buttons["aeon.library.import.folder"]
        XCTAssertTrue(button.waitForExistence(timeout: 12))
        button.tap()

        XCTAssertTrue(documentPickerIsPresented(over: app), "IMPORT FOLDER opened no picker")
        dismissDocumentPicker(over: app)
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 8))
    }

    func testCancellingAPickerLeavesNoImportErrorBehind() {
        let app = launch()
        let button = app.buttons["aeon.library.import.files"]
        XCTAssertTrue(button.waitForExistence(timeout: 12))
        button.tap()
        XCTAssertTrue(documentPickerIsPresented(over: app))
        dismissDocumentPicker(over: app)

        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 8))
        // Cancelling is not a failure, so nothing should be reported.
        XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.import.error"].exists)
        XCTAssertFalse(app.alerts.element.exists)
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
        // Some presentations offer no Cancel affordance; a downward swipe dismisses the
        // sheet instead.
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
