import XCTest
import MetalKit
@testable import App

final class SkyCameraTests: XCTestCase {
    func testPanAndPinchKeepTheAnchorPinnedAndClampScale() {
        let viewport = SkyViewport(size: CGSize(width: 390, height: 844))
        let camera = SkyCameraState(centerX: 120, centerY: -40, scale: 1.25, selectedID: nil)
        let panned = camera.panned(screenTranslation: CGSize(width: 50, height: -25))
        XCTAssertEqual(panned.centerX, 80, accuracy: 0.0001)
        XCTAssertEqual(panned.centerY, -20, accuracy: 0.0001)

        let anchor = CGPoint(x: 91, y: 318)
        let worldBefore = camera.worldPoint(for: anchor, viewport: viewport)
        let zoomed = camera.zoomed(by: 3.4, anchor: anchor, viewport: viewport)
        let worldAfter = zoomed.worldPoint(for: anchor, viewport: viewport)
        XCTAssertEqual(worldBefore.x, worldAfter.x, accuracy: 0.0001)
        XCTAssertEqual(worldBefore.y, worldAfter.y, accuracy: 0.0001)
        XCTAssertEqual(camera.zoomed(by: 100, anchor: anchor, viewport: viewport).scale, SkyCameraState.maximumScale)
        XCTAssertEqual(camera.zoomed(by: 0.0001, anchor: anchor, viewport: viewport).scale, SkyCameraState.minimumScale)
    }

    func testContentFramingAndWorldCoordinatesDoNotDependOnSafeAreas() {
        let viewport = SkyViewport(size: CGSize(width: 1_024, height: 768))
        let points = [SkyPoint(x: -200, y: -100), SkyPoint(x: 300, y: 400)]
        let camera = SkyCameraState.framing(points: points, viewport: viewport, padding: 60)
        XCTAssertEqual(camera.centerX, 50, accuracy: 0.0001)
        XCTAssertEqual(camera.centerY, 150, accuracy: 0.0001)
        for point in points {
            let screen = camera.screenPoint(for: point, viewport: viewport)
            XCTAssertTrue((60...964).contains(screen.x))
            XCTAssertTrue((60...708).contains(screen.y))
        }
        let fullBleedPoint = camera.worldPoint(for: CGPoint(x: 512, y: 384), viewport: viewport)
        XCTAssertEqual(fullBleedPoint.x, 50, accuracy: 0.0001)
        XCTAssertEqual(fullBleedPoint.y, 150, accuracy: 0.0001)
    }

    func testRotationPreservesCameraAndLocateHonorsReduceMotion() {
        let portrait = SkyViewport(size: CGSize(width: 390, height: 844))
        let landscape = SkyViewport(size: CGSize(width: 844, height: 390))
        let camera = SkyCameraState(centerX: 82, centerY: -91, scale: 1.4, selectedID: "album")
        XCTAssertEqual(camera.reframed(from: portrait, to: landscape), camera)

        let flight = SkyCameraTransition.locate(SkyPoint(x: 600, y: -240), from: camera, reduceMotion: false)
        XCTAssertEqual(flight.kind, .flight)
        XCTAssertEqual(flight.target.centerX, 600)
        XCTAssertEqual(flight.target.centerY, -240)
        XCTAssertGreaterThanOrEqual(flight.target.scale, 3.2)
        XCTAssertEqual(
            SkyCameraTransition.locate(SkyPoint(x: 0, y: 0), from: camera, reduceMotion: true).kind,
            .crossFade
        )
    }

    func testZoomTiersHaveStableBoundariesAndDoubleTapStepsOut() {
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 0.2, selectedID: nil).tier, .galaxy)
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 0.8, selectedID: nil).tier, .region)
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 2, selectedID: nil).tier, .constellation)
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 5, selectedID: nil).tier, .system)
        let viewport = SkyViewport(size: CGSize(width: 400, height: 800))
        let system = SkyCameraState(centerX: 0, centerY: 0, scale: 5, selectedID: nil)
        XCTAssertEqual(system.zoomedOutOneTier(anchor: viewport.center, viewport: viewport).scale, 2.6, accuracy: 0.0001)
    }

    func testInvalidPersistedCameraValuesRecoverToSafeBounds() {
        XCTAssertEqual(
            SkyCameraState(centerX: .infinity, centerY: 0, scale: 1, selectedID: "lost").sanitized,
            .home
        )
        XCTAssertEqual(
            SkyCameraState(centerX: 12, centerY: -8, scale: 99, selectedID: "album").sanitized,
            SkyCameraState(centerX: 12, centerY: -8, scale: SkyCameraState.maximumScale, selectedID: "album")
        )
    }

    func testCameraRoundTripsThroughTheSkyRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SkyRepository(catalog: CatalogRepository(database: try CatalogDatabase(rootURL: root)))
        let camera = SkyCameraState(centerX: 418, centerY: -92, scale: 2.4, selectedID: "album-7")

        try repository.save(camera: camera)

        XCTAssertEqual(try repository.camera(), camera)
    }

    @MainActor
    func testRendererUploadsOnlyChangedCatalogueOrSelectionBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), device: device)
        let renderer = try XCTUnwrap(SkyRenderer(view: view))
        let catalogue = try SkyComposer().compose(albums: [
            SkyAlbumInput(
                id: "album-1",
                sequence: 1,
                title: "Signal",
                artist: "Artist",
                genre: "Ambient",
                importedAt: Date(timeIntervalSince1970: 1)
            )
        ])

        renderer.update(catalogue: catalogue, camera: .home)
        renderer.update(
            catalogue: catalogue,
            camera: SkyCameraState(centerX: 40, centerY: 80, scale: 1.2, selectedID: nil)
        )
        XCTAssertEqual(renderer.stats.catalogueUploads, 1)
        XCTAssertEqual(renderer.stats.selectionUploads, 1)

        renderer.update(
            catalogue: catalogue,
            camera: SkyCameraState(centerX: 40, centerY: 80, scale: 1.2, selectedID: "album-1")
        )
        XCTAssertEqual(renderer.stats.catalogueUploads, 1)
        XCTAssertEqual(renderer.stats.selectionUploads, 2)
    }
}
