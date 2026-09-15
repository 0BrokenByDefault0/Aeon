import XCTest

/// Use the real system picker, not a mocked URL callback. Launch isolation only
/// affects storage. Actual provider selection and audio playback still need a device.
final class ImportPickerPresentationTests: XCTestCase {
    func testImportFilesPresentsTheSystemDocumentPicker() {
        checkPicker(source: "files", fromLibrary: false)
    }

    func testImportFolderPresentsTheSystemDocumentPicker() {
        checkPicker(source: "folder", fromLibrary: false)
    }

    func testLibraryFilesPresentsTheSystemDocumentPicker() {
        checkPicker(source: "files", fromLibrary: true)
    }

    func testLibraryFolderPresentsTheSystemDocumentPicker() {
        checkPicker(source: "folder", fromLibrary: true)
    }

    func testCancellingAPickerLeavesNoImportErrorBehind() {
        let app = launch()
        for source in ["files", "folder", "files"] {
            let button = app.buttons["aeon.library.import.\(source)"]
            XCTAssertTrue(waitUntilHittable(button))
            button.tap()
            guard let cancel = waitForPicker(over: app) else {
                XCTFail("System picker did not open on repeated \(source) selection")
                return
            }
            cancel.tap()
            XCTAssertTrue(waitUntilHittable(button))
            XCTAssertFalse(app.alerts.element.exists)
            XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.import.error"].exists)
        }
    }

    func testRecoveryScreensKeepNavigationCompact() {
        let app = launch()
        for destination in ["sky", "library", "playlists", "settings"] {
            let button = app.buttons["aeon.navigation.\(destination)"]
            XCTAssertTrue(waitUntilHittable(button))
            button.tap()
            let dock = app.descendants(matching: .any)["aeon.navigation.compact"].firstMatch
            XCTAssertTrue(dock.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(dock.frame.height, 60, "Tab row grew beyond its intended height")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "recovery-1-\(destination)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(app.staticTexts["aeon.settings.build-identity"].exists)
    }

    private func checkPicker(source: String, fromLibrary: Bool) {
        let app = launch()
        if fromLibrary {
            let library = app.buttons["aeon.navigation.library"]
            XCTAssertTrue(waitUntilHittable(library))
            library.tap()
        }
        let identifier = "aeon.library.import.\(source)"
        let button = app.buttons[identifier]
        XCTAssertTrue(waitUntilHittable(button))
        XCTAssertEqual(app.buttons.matching(identifier: identifier).count, 1,
                       "A hidden Sky action leaked through the Library accessibility tree")
        button.tap()
        guard let cancel = waitForPicker(over: app) else {
            XCTFail("\(source) import did not present a cancellable system Files picker")
            return
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "picker-\(fromLibrary ? "library" : "sky")-\(source)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(waitUntilHittable(button))
        XCTAssertFalse(app.alerts.element.exists)
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    private func waitForPicker(over app: XCUIApplication) -> XCUIElement? {
        let remote = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for candidate in [app, remote] {
                let cancel = candidate.buttons["Cancel"].firstMatch
                if cancel.exists && cancel.isHittable { return cancel }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AeonImportSmokeTesting"]
        app.launch()
        return app
    }
}
