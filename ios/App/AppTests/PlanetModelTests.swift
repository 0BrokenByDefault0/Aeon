import CryptoKit
import XCTest
@testable import App

final class PlanetModelTests: XCTestCase {
    private struct TextureFixture: Decodable {
        let seed: UInt64
        let colors: [[UInt8]]
        let rotationMillis: UInt32
        let turbulence: UInt16
        let hasRings: Bool
        let sha256: String
    }

    func testPlanetsFormEveryFifteenAlbumsWithStableMilestoneIdentity() throws {
        let composer = SkyComposer()
        let albums = makeAlbums(count: 65)
        let first = try composer.compose(albums: albums)
        XCTAssertEqual(first.planets.count, 4)
        XCTAssertEqual(first.planets.map { $0.members.count }, [15, 15, 15, 15])
        XCTAssertEqual(first.planets[0].members.map(\.albumID), (1...15).map { "album-\($0)" })

        var changed = Array(albums.dropFirst())
        changed[0] = makeAlbum(2, genre: "Retagged")
        let rebuilt = try composer.compose(albums: changed, preserving: first)
        XCTAssertEqual(rebuilt.planets.map(\.id), first.planets.map(\.id))
        XCTAssertEqual(rebuilt.planets.map(\.seed), first.planets.map(\.seed))
        XCTAssertEqual(rebuilt.planets.map(\.coordinate), first.planets.map(\.coordinate))
        XCTAssertEqual(rebuilt.planets.map(\.descriptor), first.planets.map(\.descriptor))
        XCTAssertEqual(rebuilt.planets[0].members.map(\.albumID), (2...16).map { "album-\($0)" })

        XCTAssertTrue(try composer.compose(albums: Array(albums.prefix(14)), preserving: first).planets.isEmpty)
    }

    func testPlanetDescriptorUsesContentAndListeningDoesNotChangeSurfaceIdentity() throws {
        let composer = SkyComposer()
        let colorful = (1...15).map { index in
            SkyAlbumInput(
                id: "album-\(index)",
                sequence: Int64(index),
                title: "Album \(index)",
                artist: "Artist \(index)",
                genre: "Ambient",
                importedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                artworkSamples: [SkyColor(red: UInt8(index * 8), green: 120, blue: 220)],
                tempo: 120,
                dynamicRange: 14,
                magnitude: 10
            )
        }
        let quiet = try composer.compose(albums: colorful)
        let loudInputs = colorful.map {
            SkyAlbumInput(
                id: $0.id, sequence: $0.sequence, title: $0.title, artist: $0.artist,
                genre: $0.genre, importedAt: $0.importedAt, artworkSamples: $0.artworkSamples,
                tempo: $0.tempo, dynamicRange: $0.dynamicRange, magnitude: 255
            )
        }
        let loud = try composer.compose(albums: loudInputs)
        XCTAssertEqual(quiet.planets.first?.descriptor, loud.planets.first?.descriptor)
        XCTAssertEqual(quiet.planets.first?.seed, loud.planets.first?.seed)
        XCTAssertEqual(quiet.planets.first?.vibrancy(using: colorful), 10)
        XCTAssertEqual(loud.planets.first?.vibrancy(using: loudInputs), 255)
        XCTAssertEqual(quiet.planets.first?.descriptor.rotationMillis, 2_000)
        XCTAssertEqual(quiet.planets.first?.descriptor.turbulence, 140)
        XCTAssertTrue(quiet.planets.first?.descriptor.hasRings == true)
        XCTAssertTrue(quiet.planets.first?.descriptor.bandColors.allSatisfy {
            $0.red % 32 == 0 && $0.green % 32 == 0 && $0.blue % 32 == 0
        } == true)
    }

    func testTextureFixturesRemainByteIdentical() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sky-catalogue-v1", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([TextureFixture].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixtures.count, 12)
        let generator = PlanetTextureGenerator()
        for fixture in fixtures {
            let colors = fixture.colors.map {
                SkyColor(red: $0[0], green: $0[1], blue: $0[2], alpha: $0.count > 3 ? $0[3] : 255)
            }
            let descriptor = PlanetDescriptor(
                algorithm: PlanetDescriptor.algorithmVersion,
                bandColors: colors,
                rotationMillis: fixture.rotationMillis,
                turbulence: fixture.turbulence,
                hasRings: fixture.hasRings
            )
            let texture = generator.rgbaTexture(seed: fixture.seed, descriptor: descriptor)
            XCTAssertEqual(texture.count, PlanetTextureGenerator.byteCount)
            XCTAssertEqual(SHA256.hash(data: texture).map { String(format: "%02x", $0) }.joined(), fixture.sha256)
        }
    }

    func testTenThousandAlbumsProduceBoundedNonoverlappingFrontierPlanets() throws {
        let start = CFAbsoluteTimeGetCurrent()
        let catalogue = try SkyComposer().compose(albums: makeAlbums(count: 10_000))
        let duration = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(catalogue.planets.count, 666)
        let members = catalogue.planets.flatMap { $0.members.map(\.albumID) }
        XCTAssertEqual(Set(members).count, 9_990)
        XCTAssertEqual(members.count, 9_990)
        // Keep this as a regression guard without making hosted-runner variance a release blocker.
        XCTAssertLessThan(duration, 20)
        for planet in catalogue.planets {
            let radius = integerSquareRoot(planet.coordinate.radiusSquared)
            XCTAssertGreaterThanOrEqual(radius, UInt64(planet.frontierRadius) + UInt64(planet.exclusionRadius))
        }
        for (index, planet) in catalogue.planets.enumerated() {
            for other in catalogue.planets.dropFirst(index + 1) {
                let minimum = UInt64(planet.exclusionRadius + other.exclusionRadius)
                XCTAssertGreaterThan(distanceSquared(planet.coordinate, other.coordinate), minimum * minimum)
            }
        }
    }

    private func makeAlbums(count: Int) -> [SkyAlbumInput] { (1...count).map { makeAlbum($0) } }

    private func makeAlbum(_ index: Int, genre: String = "Genre") -> SkyAlbumInput {
        SkyAlbumInput(
            id: "album-\(index)",
            sequence: Int64(index),
            title: "Album \(index)",
            artist: "Artist \(index)",
            genre: genre,
            importedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }

    private func integerSquareRoot(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return value }
        var low: UInt64 = 1
        var high = min(value, UInt64(UInt32.max))
        while low <= high {
            let middle = low + (high - low) / 2
            if middle <= value / middle { low = middle + 1 } else { high = middle - 1 }
        }
        return high
    }

    private func distanceSquared(_ lhs: SkyPoint, _ rhs: SkyPoint) -> UInt64 {
        let dx = Int64(lhs.x) - Int64(rhs.x)
        let dy = Int64(lhs.y) - Int64(rhs.y)
        return UInt64(dx * dx + dy * dy)
    }
}
