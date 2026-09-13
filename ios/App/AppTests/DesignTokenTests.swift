import SwiftUI
import UIKit
import XCTest
@testable import App

final class DesignTokenTests: XCTestCase {
    func testNocturneAndItsProvenanceShipInTheAppBundle() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: "AeonNocturne-Regular", withExtension: "otf"))
        XCTAssertNotNil(Bundle.main.url(forResource: "GUST-FONT-LICENSE", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "LPPL-1.3c", withExtension: "tex"))
        XCTAssertNotNil(Bundle.main.url(forResource: "README-Aeon-Nocturne", withExtension: "txt"))
        XCTAssertNotNil(UIFont(name: AeonTheme.FontToken.nocturnePostScriptName, size: 24))
        XCTAssertFalse(AeonTheme.FontToken.nocturnePostScriptName.localizedCaseInsensitiveContains("arthemys"))
    }

    func testThemeOwnsMinimumTargetsChromeClearanceAndSquareGeometry() {
        XCTAssertGreaterThanOrEqual(AeonTheme.Space.minimumTarget, 44)
        XCTAssertGreaterThan(AeonTheme.Space.compactDock, AeonTheme.Space.minimumTarget)
        XCTAssertGreaterThan(AeonTheme.Space.playerBar, AeonTheme.Space.minimumTarget)
        XCTAssertEqual(AeonTheme.Stroke.hairline, 0.5)
        XCTAssertEqual(AeonTheme.Space.textContentMaximum, 900)
    }

    func testArtworkTintIsRestrainedAndRejectsNearBlackArtwork() throws {
        let bright = image(color: UIColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        let sampled = try XCTUnwrap(AeonArtworkTint.sample(bright))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        sampled.getRed(&red, green: &green, blue: &blue, alpha: nil)
        XCTAssertLessThanOrEqual(max(red, green, blue), 0.72)
        XCTAssertGreaterThan(min(red, green, blue), 0.15)
        XCTAssertNil(AeonArtworkTint.sample(image(color: .black)))
    }

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
