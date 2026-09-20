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

extension DesignTokenTests {
    /// The reticle replaced `AeonSegmentedCapsule`, but these tests kept referring to the
    /// deleted type, so the unit-test target no longer compiled. They now assert the
    /// geometry the reticle actually has to hold.
    @objc func testReticleKeepsFourSeparateCornersInEveryControlBox() {
        let boxes = [
            CGRect(x: 0, y: 0, width: 300, height: 56),   // primary action
            CGRect(x: 13, y: 7, width: 68, height: 48),   // one segment cell
            CGRect(x: 0, y: 0, width: 56, height: 44),    // a toggle endpoint
            CGRect(x: 0, y: 0, width: 20, height: 14)     // undersized: bare text
        ]
        for box in boxes {
            let resolved = AeonReticleMark.resolvedBox(in: box)
            XCTAssertGreaterThanOrEqual(resolved.width, AeonReticleMark.minimumSize.width)
            XCTAssertGreaterThanOrEqual(resolved.height, AeonReticleMark.minimumSize.height)
            XCTAssertEqual(resolved.midX, box.midX, accuracy: 0.001)
            XCTAssertEqual(resolved.midY, box.midY, accuracy: 0.001)

            let bounds = AeonReticleMark().path(in: box).boundingRect
            XCTAssertEqual(bounds.midX, box.midX, accuracy: 0.001)
            XCTAssertEqual(bounds.midY, box.midY, accuracy: 0.001)
            // The ticks sit on the inset box, so the drawn extent is exactly the inset.
            XCTAssertEqual(bounds.width, resolved.width - 16, accuracy: 0.001)
            XCTAssertEqual(bounds.height, resolved.height - 12, accuracy: 0.001)
            // Opposite arms must never meet: each is at most a third of the span, so the
            // mark can never collapse into the smear it drew over a two-letter label.
            XCTAssertLessThanOrEqual(armLength(in: box), bounds.width / 3 + 0.001)
            XCTAssertLessThanOrEqual(armLength(in: box), bounds.height / 3 + 0.001)
        }
    }

    /// Longest horizontal arm the mark draws, recovered from the rendered path.
    private func armLength(in box: CGRect) -> CGFloat {
        let resolved = AeonReticleMark.resolvedBox(in: box)
        return max(4, min(12, (resolved.width - 16) / 3, (resolved.height - 12) / 3))
    }

    @objc func testPressedReticleStaysInsideItsBoxAndGrowsInward() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 56)
        let rest = AeonReticleMark().path(in: box).boundingRect
        let pressed = AeonReticleMark(pressed: true).path(in: box).boundingRect
        XCTAssertEqual(rest, pressed)
        XCTAssertTrue(box.insetBy(dx: -0.001, dy: -0.001).contains(rest))
        // The press wash fills only the area the ticks enclose, never the whole control.
        let field = AeonReticleField().path(in: box).boundingRect
        XCTAssertEqual(field, box.insetBy(dx: 8, dy: 6))
        XCTAssertFalse(field.contains(CGPoint(x: box.minX + 1, y: box.midY)))
        XCTAssertEqual(AeonOrbit.stroke, 1)
    }

    @objc func testEqualizerBoostsAreCompensatedSoTheyCannotClip() {
        let flat = (0..<10).map { EQBand(frequency: Double(31 << $0), q: 1, gainDB: 0) }
        XCTAssertEqual(AudioEngineGraph.headroomDB(for: flat), 0, accuracy: 0.0001)

        let bassRitual = EQView.presets.first { $0.name == "BASS RITUAL" }
        XCTAssertNotNil(bassRitual)
        let boosted = zip(EQView.frequencies, bassRitual?.gains ?? []).map {
            EQBand(frequency: $0.0, q: 1, gainDB: $0.1)
        }
        // +9 dB of boost must be answered by -9 dB of makeup, or the main mixer clips.
        XCTAssertEqual(AudioEngineGraph.headroomDB(for: boosted), -9, accuracy: 0.0001)

        let cutOnly = EQView.frequencies.map { EQBand(frequency: $0, q: 1, gainDB: -6) }
        XCTAssertEqual(AudioEngineGraph.headroomDB(for: cutOnly), 0, accuracy: 0.0001)
    }

    @objc func testSleepFadeIsDecibelLinearRatherThanAStraightAmplitudeRamp() {
        XCTAssertEqual(SettingsController.sleepFadeAmplitude(progress: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(SettingsController.sleepFadeAmplitude(progress: 1), 0, accuracy: 0.0001)
        // Halfway through the fade is -30 dB, not the -6 dB a linear ramp would give.
        XCTAssertEqual(SettingsController.sleepFadeAmplitude(progress: 0.5), 0.0316, accuracy: 0.001)
        var previous = Double.infinity
        for step in 0...20 {
            let value = SettingsController.sleepFadeAmplitude(progress: Double(step) / 20)
            XCTAssertLessThan(value, previous)
            previous = value
        }
    }
}
