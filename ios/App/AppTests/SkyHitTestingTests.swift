import XCTest
@testable import App

final class SkyHitTestingTests: XCTestCase {
    private let viewport = SkyViewport(size: CGSize(width: 400, height: 800))
    private let tester = SkyHitTester()

    func testStarsAndPlanetsUseMinimumTouchExpansionAtEveryTier() {
        let candidates = [
            SkyHitCandidate(target: .star("star"), coordinate: SkyPoint(x: 0, y: 0), visualRadius: 3),
            SkyHitCandidate(target: .planet("planet"), coordinate: SkyPoint(x: 1_000, y: 0), visualRadius: 28)
        ]
        for scale in [0.1, 0.8, 2.0, 8.0] {
            let camera = SkyCameraState(centerX: 0, centerY: 0, scale: scale, selectedID: nil)
            let starPoint = camera.screenPoint(for: SkyPoint(x: 0, y: 0), viewport: viewport)
            XCTAssertEqual(
                tester.hit(screenPoint: CGPoint(x: starPoint.x + 21, y: starPoint.y), candidates: candidates, camera: camera, viewport: viewport),
                .star("star")
            )
            let planetPoint = camera.screenPoint(for: SkyPoint(x: 1_000, y: 0), viewport: viewport)
            XCTAssertEqual(
                tester.hit(screenPoint: CGPoint(x: planetPoint.x, y: planetPoint.y + 25), candidates: candidates, camera: camera, viewport: viewport),
                .planet("planet")
            )
        }
    }

    func testOverlapsChooseNormalizedNearestThenStableSemanticPriority() {
        let camera = SkyCameraState(centerX: 0, centerY: 0, scale: 1, selectedID: nil)
        let samePoint = SkyPoint(x: 0, y: 0)
        let candidates = [
            SkyHitCandidate(target: .constellation("figure"), coordinate: samePoint, visualRadius: 28),
            SkyHitCandidate(target: .planet("planet"), coordinate: samePoint, visualRadius: 22),
            SkyHitCandidate(target: .star("star"), coordinate: samePoint, visualRadius: 4)
        ]
        XCTAssertEqual(tester.hit(screenPoint: viewport.center, candidates: candidates, camera: camera, viewport: viewport), .star("star"))

        let nearerPlanet = [
            SkyHitCandidate(target: .star("star"), coordinate: SkyPoint(x: 15, y: 0), visualRadius: 4),
            SkyHitCandidate(target: .planet("planet"), coordinate: samePoint, visualRadius: 28)
        ]
        XCTAssertEqual(tester.hit(screenPoint: viewport.center, candidates: nearerPlanet, camera: camera, viewport: viewport), .planet("planet"))
    }

    func testTransformsAndMissesAreExact() {
        let camera = SkyCameraState(centerX: 50, centerY: -20, scale: 2.5, selectedID: nil)
        let candidate = SkyHitCandidate(target: .constellation("figure"), coordinate: SkyPoint(x: 80, y: 12), visualRadius: 28)
        let screen = camera.screenPoint(for: candidate.coordinate, viewport: viewport)
        XCTAssertEqual(tester.hit(screenPoint: screen, candidates: [candidate], camera: camera, viewport: viewport), .constellation("figure"))
        XCTAssertNil(tester.hit(screenPoint: CGPoint(x: screen.x + 80, y: screen.y), candidates: [candidate], camera: camera, viewport: viewport))
    }
}
