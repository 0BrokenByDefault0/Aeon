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

    func testArchivoShipsWithItsLicenceAndResolvesBothWidths() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: AeonTheme.FontToken.resourceName, withExtension: "ttf"))
        XCTAssertNotNil(Bundle.main.url(forResource: "OFL-Archivo", withExtension: "txt"))
        let display = AeonTheme.FontToken.uiDisplay(size: 34)
        let ui = AeonTheme.FontToken.uiText(size: 34)
        XCTAssertTrue(display.familyName.hasPrefix(AeonTheme.FontToken.family), display.familyName)
        XCTAssertTrue(ui.familyName.hasPrefix(AeonTheme.FontToken.family), ui.familyName)
        // Display type is the same face set wider; if the variation axis stops
        // being applied the two collapse into one and the hierarchy is lost.
        let name = "Aeon" as NSString
        XCTAssertGreaterThan(
            name.size(withAttributes: [.font: display]).width,
            name.size(withAttributes: [.font: ui]).width
        )
    }

    func testEveryWeightTheInterfaceUsesResolvesToABundledInstance() {
        // The UI role addresses the face by the PostScript name of a named
        // instance so SwiftUI keeps scaling it with Dynamic Type. If an
        // instance name drifts, the app silently falls back to the system font.
        for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
            let name = AeonTheme.FontToken.instanceName(for: weight)
            XCTAssertNotNil(UIFont(name: name, size: 15), name)
        }
    }

    func testInstrumentGeometryIsRoundedAndSpacingRunsOneScale() {
        XCTAssertGreaterThan(AeonTheme.Radius.small, 0)
        XCTAssertLessThan(AeonTheme.Radius.small, AeonTheme.Radius.medium)
        XCTAssertLessThan(AeonTheme.Radius.medium, AeonTheme.Radius.large)
        XCTAssertLessThan(AeonTheme.Radius.large, AeonTheme.Radius.sheet)
        XCTAssertEqual(
            [AeonTheme.Space.small, AeonTheme.Space.medium, AeonTheme.Space.large,
             AeonTheme.Space.section, AeonTheme.Space.vast],
            [AeonTheme.Space.small, AeonTheme.Space.medium, AeonTheme.Space.large,
             AeonTheme.Space.section, AeonTheme.Space.vast].sorted()
        )
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
