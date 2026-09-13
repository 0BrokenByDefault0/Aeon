import Foundation
import CoreGraphics
import ImageIO

enum SkyRepositoryError: Error, Equatable {
    case decodeFailed(String)
    case recordConflict(String)
}

final class SkyRepository {
    private let catalog: CatalogRepository
    private let artworkStore: ArtworkStore?
    private let composer: SkyComposer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(catalog: CatalogRepository, artworkStore: ArtworkStore? = nil, composer: SkyComposer = SkyComposer()) {
        self.catalog = catalog
        self.artworkStore = artworkStore
        self.composer = composer
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func catalogue() throws -> SkyCatalogue {
        SkyCatalogue(
            regions: try decodedRecords(kind: .region, as: SkyRegion.self),
            constellations: try decodedRecords(kind: .constellation, as: SkyConstellation.self),
            stars: try decodedRecords(kind: .star, as: SkyStar.self),
            planets: try decodedRecords(kind: .planet, as: SkyPlanet.self)
        )
    }

    @discardableResult
    func backfill(inputs: [SkyAlbumInput]? = nil) throws -> SkyCatalogue {
        let existing = try catalogue()
        let source = try inputs ?? catalogInputs()
        let composed = try composer.compose(albums: source, preserving: existing)
        try persist(composed, preserving: existing)
        return composed
    }

    private func catalogInputs() throws -> [SkyAlbumInput] {
        var result: [SkyAlbumInput] = []
        var offset = 0
        while true {
            let page = try catalog.albumPage(offset: offset, limit: CatalogDatabase.maximumPageSize, sort: .artist)
            result.append(contentsOf: page.map {
                SkyAlbumInput(
                    id: $0.id,
                    sequence: $0.sequence,
                    title: $0.title,
                    artist: $0.artist,
                    genre: $0.genre,
                    importedAt: $0.importedAt,
                    artworkSamples: artworkSamples(for: $0.artworkKey),
                    magnitude: UInt8(clamping: 40 + min(180, $0.playCount * 4))
                )
            })
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
        return result
    }

    private func artworkSamples(for key: String?) -> [SkyColor] {
        guard let key, let artworkStore,
              let url = try? artworkStore.url(forKey: key),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 16,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return [] }
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        let positions = [1, 5, 9, 13]
        return positions.flatMap { y in
            positions.map { x in
                let offset = (y * width + x) * 4
                return SkyColor(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
            }
        }
    }

    private func persist(_ catalogue: SkyCatalogue, preserving existing: SkyCatalogue) throws {
        let oldStars = Dictionary(uniqueKeysWithValues: existing.stars.map { ($0.albumID, $0) })
        let oldPlanets = Dictionary(uniqueKeysWithValues: existing.planets.map { ($0.id, $0) })
        for star in catalogue.stars {
            if let old = oldStars[star.albumID], old != star { throw SkyRepositoryError.recordConflict(star.albumID) }
        }
        for planet in catalogue.planets {
            if let old = oldPlanets[planet.id], old != planet { throw SkyRepositoryError.recordConflict(planet.id) }
        }

        let records = try makeRecords(catalogue)
        let existingRecords = try allRecords()
        let existingByID = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.id, $0) })
        let changes = records.filter { record in
            guard let old = existingByID[record.id] else { return true }
            return old.kind != record.kind || old.sequence != record.sequence || old.payload != record.payload
        }
        guard !changes.isEmpty else { return }
        try catalog.database.transaction {
            for record in changes {
                try catalog.database.execute(
                    """
                    INSERT INTO sky_records(id, kind, sequence, payload, updated_at) VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, sequence = excluded.sequence,
                        payload = excluded.payload, updated_at = excluded.updated_at
                    """,
                    [.text(record.id), .text(record.kind.rawValue), .integer(record.sequence),
                     .blob(record.payload), .real(record.updatedAt.timeIntervalSince1970)]
                )
            }
        }
    }

    private func makeRecords(_ catalogue: SkyCatalogue) throws -> [SkyRecord] {
        var records: [SkyRecord] = []
        for (index, region) in catalogue.regions.enumerated() {
            records.append(try record(id: region.id, kind: .region, sequence: Int64(index), value: region, date: .distantPast))
        }
        for (index, constellation) in catalogue.constellations.enumerated() {
            records.append(try record(id: constellation.id, kind: .constellation, sequence: Int64(index), value: constellation, date: .distantPast))
        }
        for star in catalogue.stars {
            records.append(try record(id: "star:\(star.albumID)", kind: .star, sequence: star.sequence, value: star, date: star.placedAt))
        }
        for planet in catalogue.planets {
            records.append(try record(id: planet.id, kind: .planet, sequence: Int64(planet.index), value: planet, date: planet.formationTimestamp))
        }
        return records
    }

    private func record<Value: Encodable>(
        id: String,
        kind: SkyRecordKind,
        sequence: Int64,
        value: Value,
        date: Date
    ) throws -> SkyRecord {
        SkyRecord(id: id, kind: kind, sequence: sequence, payload: try encoder.encode(value), updatedAt: date)
    }

    private func decodedRecords<Value: Decodable>(kind: SkyRecordKind, as type: Value.Type) throws -> [Value] {
        try records(kind: kind).map { record in
            do { return try decoder.decode(type, from: record.payload) }
            catch { throw SkyRepositoryError.decodeFailed(record.id) }
        }
    }

    private func records(kind: SkyRecordKind) throws -> [SkyRecord] {
        var records: [SkyRecord] = []
        var offset = 0
        while true {
            let page = try catalog.skyRecords(kind: kind, offset: offset, limit: CatalogDatabase.maximumPageSize)
            records.append(contentsOf: page)
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
        return records
    }

    private func allRecords() throws -> [SkyRecord] {
        try SkyRecordKind.allCases.flatMap { try records(kind: $0) }
    }
}
