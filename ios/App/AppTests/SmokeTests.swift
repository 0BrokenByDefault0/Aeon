import XCTest
@testable import App

final class SmokeTests: XCTestCase {
    func testAeonFiveNativeTestTargetLoads() {
        XCTAssertEqual(2 + 2, 4)
    }
}
