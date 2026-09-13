import XCTest

final class AppUITests: XCTestCase {
    func testNativeRootLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 10))
    }
}
