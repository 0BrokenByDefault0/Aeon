import XCTest
@testable import App

final class SkyComposerTests: XCTestCase {
    func testCompositionMatchesPreSimplificationCatalogues() throws {
        let genres = ["Jazz", "Rock", "", "Uncharted", "Various Artists"]
        var albums: [SkyAlbumInput] = []
        for index in 1...240 {
            let artist = "Artist \(index % 17)"
            let date = Date(timeIntervalSince1970: Double(index / 3))
            let canonical: String? = index % 7 == 0 ? "Ambient" : nil
            albums.append(SkyAlbumInput(
                id: "album-\(index)", sequence: Int64(index), title: "Album \(index)",
                artist: artist, genre: genres[index % 5], importedAt: date,
                isCompilation: index % 19 == 0, canonicalArtistGenre: canonical
            ))
        }
        let composer = SkyComposer()
        let initial = try composer.compose(albums: Array(albums.prefix(80)))
        let incremental = try composer.compose(albums: albums.reversed(), preserving: initial)
        let full = try composer.compose(albums: albums)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprints = try [initial, incremental, full].map {
            SkyStableHash.value(String(decoding: try encoder.encode($0), as: UTF8.self))
        }
        // Recorded from b7eaa57: includes coordinates, regions, figures, and planet cohorts.
        XCTAssertEqual(fingerprints, [14537898339054895489, 4308177784464051124, 8699994634793629668])
    }

    func testGrammarProducesOneStarPerAlbumAndFiguresOnlyForRealRepeatedArtists() throws {
        let catalogue = try SkyComposer().compose(albums: [
            album(1, artist: "Autechre", genre: "Electronic"),
            album(2, artist: "Autechre", genre: "Electronic"),
            album(3, artist: "Björk", genre: "Art Pop"),
            album(4, artist: "Various Artists", genre: "Ambient", compilation: true),
            album(5, artist: "Unknown", genre: "")
        ])

        XCTAssertEqual(catalogue.stars.count, 5)
        XCTAssertEqual(catalogue.constellations.count, 1)
        XCTAssertEqual(catalogue.constellations.first?.artistName, "Autechre")
        XCTAssertEqual(catalogue.constellations.first?.figureSegments.count, 1)
        XCTAssertFalse(catalogue.constellations.contains { $0.artistName == "Various Artists" })
        XCTAssertEqual(catalogue.regions.first { $0.id == SkyRegionIdentity.uncharted }?.starCount, 1)
        XCTAssertTrue(catalogue.stars.first { $0.albumID == "album-5" }?.isUncharted == true)
    }

    func testPlacementPrecedenceAndEarliestImportTieBreakAreExact() throws {
        let albums = [
            album(1, artist: "Compilation", genre: "Jazz", compilation: true),
            album(2, artist: "Agree", genre: "House"),
            album(3, artist: "Agree", genre: " house "),
            album(4, artist: "Canonical", genre: "Rock", canonical: "Electronic"),
            album(5, artist: "Canonical", genre: "Jazz", canonical: "Electronic"),
            album(6, artist: "Tie", genre: "Folk"),
            album(7, artist: "Tie", genre: "Metal"),
            album(8, artist: "Blank", genre: "")
        ]
        let stars = Dictionary(uniqueKeysWithValues: try SkyComposer().compose(albums: albums).stars.map { ($0.albumID, $0) })

        XCTAssertEqual(stars["album-1"]?.regionID, SkyRegionIdentity.variousArtists)
        XCTAssertEqual(stars["album-2"]?.regionID, "region:house")
        XCTAssertEqual(stars["album-3"]?.regionID, "region:house")
        XCTAssertEqual(stars["album-4"]?.regionID, "region:electronic")
        XCTAssertEqual(stars["album-5"]?.regionID, "region:electronic")
        XCTAssertEqual(stars["album-6"]?.regionID, "region:folk")
        XCTAssertEqual(stars["album-7"]?.regionID, "region:folk")
        XCTAssertEqual(stars["album-8"]?.regionID, SkyRegionIdentity.uncharted)
    }

    func testCoordinatesSurviveRebuildMetadataPlaybackAndInputOrderChanges() throws {
        let composer = SkyComposer()
        let original = [
            album(1, artist: "One", genre: "Ambient"),
            album(2, artist: "Two", genre: "Jazz")
        ]
        let first = try composer.compose(albums: original)
        var changed = original.reversed().map { value in
            album(
                Int(value.sequence),
                artist: value.artist + " Edited",
                genre: "Different",
                magnitude: 240
            )
        }
        changed.append(album(3, artist: "One", genre: "Ambient"))
        let rebuilt = try composer.compose(albums: changed, preserving: first)

        for old in first.stars {
            XCTAssertEqual(rebuilt.stars.first { $0.albumID == old.albumID }?.coordinate, old.coordinate)
            XCTAssertEqual(rebuilt.stars.first { $0.albumID == old.albumID }?.regionID, old.regionID)
        }
        let added = try XCTUnwrap(rebuilt.stars.first { $0.albumID == "album-3" })
        let anchor = try XCTUnwrap(first.stars.first { $0.albumID == "album-1" })
        XCTAssertLessThan(distanceSquared(added.coordinate, anchor.coordinate), UInt64(512 * 512))
    }

    func testUnchartedCoordinatesDoNotDependOnArrivalOrder() throws {
        let composer = SkyComposer()
        let values = (1...100).map { album($0, artist: "Unknown \($0)", genre: "") }
        let forward = try composer.compose(albums: values)
        let reverse = try composer.compose(albums: values.reversed())
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: forward.stars.map { ($0.albumID, $0.coordinate) }),
            Dictionary(uniqueKeysWithValues: reverse.stars.map { ($0.albumID, $0.coordinate) })
        )
        XCTAssertTrue(forward.constellations.isEmpty)
        XCTAssertTrue(forward.regions.first { $0.id == SkyRegionIdentity.uncharted }?.isUncharted == true)
    }

    func testRepositoryBackfillPersistsStarsAndIsANoOpWhenRepeated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        let sky = SkyRepository(catalog: catalog)
        let inputs = (1...40).map { album($0, artist: "Artist \($0 / 2)", genre: "Electronic") }

        let first = try sky.backfill(inputs: inputs)
        let rowsBefore = try catalog.database.query("SELECT id, payload, updated_at FROM sky_records ORDER BY id")
        let second = try sky.backfill(inputs: inputs)
        let rowsAfter = try catalog.database.query("SELECT id, payload, updated_at FROM sky_records ORDER BY id")

        XCTAssertEqual(first, second)
        XCTAssertEqual(rowsBefore, rowsAfter)
        XCTAssertEqual(try sky.catalogue(), first)
    }

    private func album(
        _ index: Int,
        artist: String,
        genre: String,
        compilation: Bool = false,
        canonical: String? = nil,
        magnitude: UInt8 = 48
    ) -> SkyAlbumInput {
        SkyAlbumInput(
            id: "album-\(index)",
            sequence: Int64(index),
            title: "Album \(index)",
            artist: artist,
            genre: genre,
            importedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            isCompilation: compilation,
            canonicalArtistGenre: canonical,
            magnitude: magnitude
        )
    }

    private func distanceSquared(_ lhs: SkyPoint, _ rhs: SkyPoint) -> UInt64 {
        let dx = Int64(lhs.x) - Int64(rhs.x)
        let dy = Int64(lhs.y) - Int64(rhs.y)
        return UInt64(dx * dx + dy * dy)
    }
}
