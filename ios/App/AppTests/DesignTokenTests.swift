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

    func testLoadedPausedTrackStillResolvesArtworkTint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artworkStore = try ArtworkStore(rootURL: root.appendingPathComponent("Artwork"))
        let artwork = try XCTUnwrap(image(color: .orange).jpegData(compressionQuality: 0.9))
        let artworkKey = try artworkStore.store(artwork, key: "loaded-paused")
        let catalog = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        let date = Date(timeIntervalSince1970: 1)
        try catalog.insertAlbum(
            CatalogAlbum(
                id: "album", sequence: 1, title: "Album", artist: "Artist", year: "2026",
                genre: "Ambient", artworkKey: artworkKey, importedAt: date, updatedAt: date
            ),
            tracks: [CatalogTrack(
                id: "track", albumID: "album", sequence: 1, discNumber: 1, trackNumber: 1,
                title: "Track", artist: "", duration: 60, byteCount: 1,
                mediaReference: .native(relativePath: "track.wav"), importedAt: date
            )]
        )

        let paused = PlaybackSnapshot(
            version: 1,
            trackID: "track",
            queueRevision: 1,
            queue: [QueueItem(trackID: "track", albumID: "album", mediaRef: .native(relativePath: "track.wav"))],
            queueIndex: 0,
            position: 12,
            intent: .paused,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 1,
            eqEnabled: false,
            eqBands: [],
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: date
        )
        XCTAssertNotNil(AeonArtworkTint.resolve(
            trackID: paused.trackID,
            catalog: catalog,
            artworkStore: artworkStore
        ))
    }

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

extension DesignTokenTests {
    @MainActor
    @objc func testOpaquePanelRendersIdenticallyAboveBlackAndWhiteContent() throws {
        let black = try panelImage(over: .black)
        let white = try panelImage(over: .white)
        XCTAssertEqual(black, white, "Utility panels must not blend the underlying Sky into their pixels")
    }

    @MainActor
    private func panelImage(over background: Color) throws -> Data {
        let renderer = ImageRenderer(content:
            ZStack {
                background
                AeonGlass { Color.clear.frame(width: 80, height: 80) }
                    .modifier(AeonOpaquePanel())
            }
            .frame(width: 80, height: 80)
            .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage?.pngData())
    }

    @objc func testTabRuleIsCenteredInEachTabIncludingSky() {
        for width: CGFloat in [44, 78, 108, 210] {
            for index in 0..<4 {
                let rect = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: AeonOrbit.stroke)
                let bounds = AeonTabSelectionRule().path(in: rect).boundingRect
                XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.001)
                XCTAssertEqual(bounds.width, 24, accuracy: 0.001)
                XCTAssertEqual(bounds.midY, AeonOrbit.stroke / 2, accuracy: 0.001)
            }
        }
    }

    @objc func testQuietSkyHasTwoDistinctEdgeReadingsRatherThanDuplicateQuadrants() {
        XCTAssertEqual(AeonQuietSkyMarkers.labels, ["UNCHARTED", "UNLIT"])
        XCTAssertEqual(Set(AeonQuietSkyMarkers.labels).count, 2)
    }
}
