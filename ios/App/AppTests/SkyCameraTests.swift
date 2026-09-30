import XCTest
import MetalKit
import UIKit
@testable import App

final class SkyCameraTests: XCTestCase {
    @MainActor
    func testCollectionFitIncludesPlanetRingsAndClearsChromeAcrossViewports() throws {
        for name in ["one", "fifteen", "world-family-4", "1000"] {
            let sky = try SkySceneController.fixture(named: name)
            let points = sky.stars.map(\.coordinate) + sky.planets.map(\.coordinate)
            for (size, top, bottom) in [(CGSize(width: 320, height: 568), 88.0, 150.0),
                                       (CGSize(width: 430, height: 932), 110.0, 180.0),
                                       (CGSize(width: 844, height: 390), 64.0, 90.0),
                                       (CGSize(width: 320, height: 568), 100.0, 240.0)] {
                let viewport = SkyViewport(size: size)
                let bounds = CGRect(x: 0, y: top, width: size.width, height: size.height - top - bottom)
                let camera = SkyCameraState.framingCollection(points: points, planets: sky.planets,
                    viewport: viewport, usableBounds: bounds)
                let projected = points.map { camera.screenPoint(for: $0, viewport: viewport) }
                XCTAssertEqual((projected.map(\.x).min()! + projected.map(\.x).max()!) / 2, bounds.midX, accuracy: 0.001)
                XCTAssertEqual((projected.map(\.y).min()! + projected.map(\.y).max()!) / 2, bounds.midY, accuracy: 0.001)
                for point in projected { XCTAssertTrue(bounds.insetBy(dx: 12, dy: 12).contains(point), name) }
                for planet in sky.planets {
                    let point = camera.screenPoint(for: planet.coordinate, viewport: viewport)
                    let extent = planet.resolvedMaterial.ringExtent
                    let radius = PlanetProjection.bodyRadius(scale: camera.scale, usableSize: bounds.size,
                        ringExtent: extent) * CGFloat(max(1.08, extent))
                    XCTAssertTrue(bounds.contains(CGRect(x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2)), name)
                }
            }
        }
    }

    func testTextFreeZoomIsReachableWithoutChangingTheLabelHierarchy() {
        for fit in [0.72, 0.2, 0.015, 0.000008] {
            XCTAssertEqual(SkyDisclosure.textOpacity(scale: fit, collectionScale: fit), 1)
            XCTAssertEqual(SkyDisclosure.textOpacity(scale: fit * 0.7, collectionScale: fit), 0.5, accuracy: 0.000001)
            XCTAssertEqual(SkyDisclosure.textOpacity(scale: fit * 0.5, collectionScale: fit), 0)
            let minimum = max(SkyCameraState.minimumScale, fit * 0.25)
            XCTAssertEqual(SkyDisclosure.textOpacity(scale: minimum, collectionScale: fit), 0)
        }
    }

    @MainActor
    func testLaunchFitsCollectionAndTextChoicePersistsWithoutMovingExploredCamera() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        let repository = SkyRepository(catalog: catalog)
        let playback = PlaybackController(coordinator: PlaybackFixtureCoordinator(snapshot: nil))
        let inputs = (1...33).map { index in
            SkyAlbumInput(id: "album-\(index)", sequence: Int64(index), title: "Album \(index)",
                artist: "Artist \(index / 3)", genre: "Jazz", importedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let controller = SkySceneController(repository: repository, catalog: catalog, playback: playback)
        XCTAssertEqual(controller.camera, .home)
        try repository.backfill(inputs: inputs)
        controller.reload() // The first asynchronous import must also receive a fit.
        controller.updateViewport(CGSize(width: 320, height: 568))
        controller.updateFocusInsets(top: 90, bottom: 150)
        XCTAssertEqual(controller.camera, controller.collectionCamera)
        XCTAssertNil(controller.camera.selectedID)
        let viewport = SkyViewport(size: CGSize(width: 320, height: 568))
        let anchor = CGPoint(x: 80, y: 220)
        let worldBefore = controller.camera.worldPoint(for: anchor, viewport: viewport)
        controller.zoom(by: 0.001, anchor: anchor, viewport: viewport, persist: true)
        XCTAssertEqual(controller.skyTextOpacity, 0)
        let worldAfter = controller.camera.worldPoint(for: anchor, viewport: viewport)
        XCTAssertEqual(worldBefore.x, worldAfter.x, accuracy: 0.001)
        XCTAssertEqual(worldBefore.y, worldAfter.y, accuracy: 0.001)
        let explored = controller.camera
        controller.toggleText()
        controller.updateFocusInsets(top: 90, bottom: 240)
        controller.updateViewport(CGSize(width: 844, height: 390))
        XCTAssertEqual(controller.camera, explored, "Text controls and layout must not reset exploration")
        let relaunched = SkySceneController(repository: repository, catalog: catalog, playback: playback)
        XCTAssertEqual(relaunched.camera, relaunched.collectionCamera)
        XCTAssertNotEqual(relaunched.camera, explored, "A new launch must ignore the old pan/zoom")
        XCTAssertTrue(relaunched.textHidden)
        XCTAssertEqual(relaunched.skyTextOpacity, 0)
        relaunched.toggleText()
        XCTAssertEqual(relaunched.skyTextOpacity, 1)
    }

    @MainActor
    func testSelectingPlanetKeepsTheRenderedCollectionIlluminated() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let sky = try SkySceneController.fixture(named: "thirty-three")
        let size = CGSize(width: 390, height: 844)
        var camera = SkyCameraState.framingCollection(
            points: sky.stars.map(\.coordinate) + sky.planets.map(\.coordinate), planets: sky.planets,
            viewport: SkyViewport(size: size), usableBounds: CGRect(origin: .zero, size: size))
        let before: UIImage? = await withCheckedContinuation { continuation in
            SkyRenderer.capture(catalogue: sky, camera: camera, playingStarID: nil, size: size) {
                continuation.resume(returning: $0)
            }
        }
        camera.selectedID = try XCTUnwrap(sky.planets.first).id
        let after: UIImage? = await withCheckedContinuation { continuation in
            SkyRenderer.capture(catalogue: sky, camera: camera, playingStarID: nil, size: size) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(try XCTUnwrap(before?.pngData()), try XCTUnwrap(after?.pngData()),
            "Selecting a world must leave other worlds, stars and constellations illuminated")
    }

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
        XCTAssertEqual(camera.zoomed(by: 0.00000001, anchor: anchor, viewport: viewport).scale, SkyCameraState.minimumScale)
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
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 0.2, selectedID: nil).tier, .collection)
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 0.8, selectedID: nil).tier, .system)
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 2, selectedID: nil).tier, .album)
        XCTAssertEqual(SkyCameraState(centerX: 0, centerY: 0, scale: 5, selectedID: nil).tier, .focus)
        let viewport = SkyViewport(size: CGSize(width: 400, height: 800))
        let system = SkyCameraState(centerX: 0, centerY: 0, scale: 5, selectedID: nil)
        XCTAssertEqual(system.zoomedOutOneTier(anchor: viewport.center, viewport: viewport).scale, 2.4, accuracy: 0.0001)
    }

    func testArtistFocusFramesActualMembersAtAnyWorldExtent() {
        let viewport = SkyViewport(size: CGSize(width: 390, height: 844))
        let points = [SkyPoint(x: 900, y: -340), SkyPoint(x: 1040, y: -280), SkyPoint(x: 960, y: -220)]
        let camera = SkyCameraState.focusFraming(points: points, viewport: viewport)
        let projected = points.map { camera.screenPoint(for: $0, viewport: viewport) }
        let width = projected.map(\.x).max()! - projected.map(\.x).min()!
        let height = projected.map(\.y).max()! - projected.map(\.y).min()!
        let focusSize = max(width, height)
        let usableShortEdge = min(viewport.size.width, viewport.size.height)

        XCTAssertGreaterThanOrEqual(focusSize, usableShortEdge * 0.35)
        XCTAssertLessThanOrEqual(focusSize, usableShortEdge * 0.55)
        XCTAssertGreaterThan(camera.scale, SkyCameraState.home.scale)
    }

    func testAlbumFocusKeepsOneAnchorAndClampDoesNotUndoPinch() {
        let point = SkyPoint(x: 900, y: -340)
        let viewport = SkyViewport(size: CGSize(width: 390, height: 844))
        let focused = SkyCameraState.albumFocus(point, id: "one")
        XCTAssertEqual(focused.screenPoint(for: point, viewport: viewport), viewport.center)
        XCTAssertEqual(focused.scale, 5)
        XCTAssertEqual(focused.selectedID, "one")
        let anchor = CGPoint(x: 70, y: 280)
        let before = focused.worldPoint(for: anchor, viewport: viewport)
        let zoomed = focused.zoomed(by: 0.7, anchor: anchor, viewport: viewport).constrained(to: [point], viewport: viewport)
        let after = zoomed.worldPoint(for: anchor, viewport: viewport)
        XCTAssertEqual(before.x, after.x, accuracy: 0.0001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.0001)
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

    func testDisclosureReversesWithoutSelectionOverridesOrDarkIntervals() {
        XCTAssertEqual(SkyDisclosure(scale: 0.4).region, 1)
        XCTAssertEqual(SkyDisclosure(scale: 1).artist, 1)
        XCTAssertEqual(SkyDisclosure(scale: 2).album, 1)
        for scale in stride(from: 0.3, through: 2.2, by: 0.02) {
            let state = SkyDisclosure(scale: scale)
            XCTAssertEqual(state.region + state.artist + state.album, 1, accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(max(state.region, state.artist, state.album), 0.5)
        }
    }

    func testDenseConstellationLabelClearsItsMembers() throws {
        let viewport = CGSize(width: 390, height: 844)
        let bounds = CGRect(x: 0, y: 120, width: 390, height: 600)
        let points = stride(from: 120, through: 270, by: 25).flatMap { x in
            stride(from: 300, through: 450, by: 25).map { y in CGPoint(x: CGFloat(x), y: CGFloat(y)) }
        }
        let candidate = try XCTUnwrap(SkyLabelLayout.groupCandidate(id: "artist-sza", text: "SZA",
            isRegion: false, points: points, usableBounds: bounds, opacity: 1))
        let obstacles = points.map { CGRect(x: $0.x - 9, y: $0.y - 9, width: 18, height: 18) }
        let labels = SkyLabelLayout.place([candidate], viewport: viewport, obstacles: obstacles, usableBounds: bounds)
        let label = try XCTUnwrap(labels.first)
        XCTAssertEqual(label.text, "SZA")
        XCTAssertTrue(bounds.contains(label.frame))
        XCTAssertFalse(obstacles.contains { $0.insetBy(dx: -8, dy: -6).intersects(label.frame) })
    }

    func testPartlyVisibleRegionUsesItsVisibleMembersAndBlockedLabelsDoNotConsumeBudget() throws {
        let viewport = CGSize(width: 390, height: 844)
        let bounds = CGRect(x: 0, y: 120, width: 390, height: 600)
        let group = try XCTUnwrap(SkyLabelLayout.groupCandidate(id: "region-soul", text: "SOUL",
            isRegion: true, points: [CGPoint(x: -900, y: 350), CGPoint(x: 300, y: 350)],
            usableBounds: bounds, opacity: 1))
        XCTAssertEqual(group.anchor, CGPoint(x: 300, y: 350))
        let blocked = SkyLabelLayout.Candidate(id: "blocked", text: "Hidden", anchor: CGPoint(x: -900, y: -900), isRegion: false)
        let labels = SkyLabelLayout.place([blocked, group], viewport: viewport, usableBounds: bounds, limit: 1)
        XCTAssertEqual(labels.map(\.id), ["region-soul"])
    }

    func testSkyLabelPlacementKeepsReadoutsOnscreenAndCollisionFree() {
        let candidates = (0..<8).map { index in
            SkyLabelLayout.Candidate(
                id: "label-\(index)",
                text: "CONSTELLATION \(index)",
                anchor: CGPoint(x: 190 + CGFloat(index % 2), y: 360 + CGFloat(index % 3)),
                isRegion: false
            )
        }
        let viewport = CGSize(width: 390, height: 844)
        let labels = SkyLabelLayout.place(candidates, viewport: viewport)

        XCTAssertFalse(labels.isEmpty)
        for (index, label) in labels.enumerated() {
            XCTAssertGreaterThanOrEqual(label.frame.minX, 8)
            XCTAssertGreaterThanOrEqual(label.frame.minY, 176)
            XCTAssertLessThanOrEqual(label.frame.maxX, viewport.width - 8)
            XCTAssertLessThanOrEqual(label.frame.maxY, viewport.height - 96)
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.insetBy(dx: -8, dy: -6).intersects(other.frame))
            }
        }
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
