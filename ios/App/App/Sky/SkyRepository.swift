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

    func camera() throws -> SkyCameraState? {
        guard let record = try records(kind: .camera).first else { return nil }
        do { return try decoder.decode(SkyCameraState.self, from: record.payload).sanitized }
        catch { throw SkyRepositoryError.decodeFailed(record.id) }
    }

    func save(camera: SkyCameraState) throws {
        try catalog.upsertSkyRecord(SkyRecord(
            id: "camera:primary",
            kind: .camera,
            sequence: 0,
            payload: try encoder.encode(camera.sanitized),
            updatedAt: Date()
        ))
    }

    @discardableResult
    func backfill(inputs: [SkyAlbumInput]? = nil) throws -> SkyCatalogue {
        let existing = try catalogue()
        let source = try inputs ?? catalogInputs()
        let composed = try composer.compose(albums: source, preserving: existing)
        try persist(composed, preserving: existing)
        return composed
    }

    func affectedAlbumCount(for updatedAlbum: CatalogAlbum) throws -> Int {
        let existing = try catalogue()
        let source = try catalogInputs(replacing: updatedAlbum)
        let oldKey = existing.stars.first { $0.albumID == updatedAlbum.id }?.artistKey
        let newKey = source.first { $0.id == updatedAlbum.id }.map(SkyComposer.artistKey)
        let keys = Set([oldKey, newKey].compactMap { $0 })
        return source.filter { keys.contains(SkyComposer.artistKey(for: $0)) }.count
    }

    @discardableResult
    func rechart(updatedAlbum: CatalogAlbum) throws -> SkyCatalogue {
        let existing = try catalogue()
        let source = try catalogInputs(replacing: updatedAlbum)
        let oldKey = existing.stars.first { $0.albumID == updatedAlbum.id }?.artistKey
        let newKey = source.first { $0.id == updatedAlbum.id }.map(SkyComposer.artistKey)
        let keys = Set([oldKey, newKey].compactMap { $0 })
        let affectedIDs = Set(source.filter { keys.contains(SkyComposer.artistKey(for: $0)) }.map(\.id))
        let preserved = SkyCatalogue(
            regions: [],
            constellations: [],
            stars: existing.stars.filter { !affectedIDs.contains($0.albumID) },
            planets: existing.planets
        )
        var composed = try composer.compose(albums: source, preserving: preserved)
        composed = enforceMovement(in: composed, from: existing, affectedIDs: affectedIDs)
        let rewrite = try rewritePlan(for: composed)
        try catalog.updateAlbumAndSky(
            updatedAlbum,
            records: rewrite.records,
            deletingSkyRecordIDs: rewrite.deletingIDs
        )
        return composed
    }

    @discardableResult
    func deleteAlbum(id: String) throws -> Bool {
        let existing = try catalogue()
        let source = try catalogInputs(deletingAlbumID: id)
        let retainedPlanets = existing.planets.compactMap { planet -> SkyPlanet? in
            let members = planet.members.filter { $0.albumID != id }
            guard !members.isEmpty else { return nil }
            return SkyPlanet(
                index: planet.index,
                members: members,
                frontierRadius: planet.frontierRadius,
                formationTimestamp: planet.formationTimestamp,
                seed: planet.seed,
                coordinate: planet.coordinate,
                exclusionRadius: planet.exclusionRadius,
                descriptor: planet.descriptor,
                material: planet.resolvedMaterial
            )
        }
        let preserved = SkyCatalogue(
            regions: [],
            constellations: [],
            stars: existing.stars.filter { $0.albumID != id },
            planets: retainedPlanets
        )
        let composed = try composer.compose(albums: source, preserving: preserved)
        let rewrite = try rewritePlan(for: composed)
        return try catalog.deleteAlbumAndRewriteSky(
            id: id,
            records: rewrite.records,
            deletingSkyRecordIDs: rewrite.deletingIDs
        )
    }

    private func catalogInputs(
        replacing updatedAlbum: CatalogAlbum? = nil,
        deletingAlbumID: String? = nil
    ) throws -> [SkyAlbumInput] {
        var result: [SkyAlbumInput] = []
        var offset = 0
        while true {
            let page = try catalog.albumPage(offset: offset, limit: CatalogDatabase.maximumPageSize, sort: .artist)
            result.append(contentsOf: page.compactMap {
                if $0.id == deletingAlbumID { return nil }
                let title = $0.id == updatedAlbum?.id ? updatedAlbum!.title : $0.title
                let artist = $0.id == updatedAlbum?.id ? updatedAlbum!.artist : $0.artist
                let genre = $0.id == updatedAlbum?.id ? updatedAlbum!.genre : $0.genre
                let artworkKey = $0.id == updatedAlbum?.id ? updatedAlbum!.artworkKey : $0.artworkKey
                return SkyAlbumInput(
                    id: $0.id,
                    sequence: $0.sequence,
                    title: title,
                    artist: artist,
                    genre: genre,
                    importedAt: $0.importedAt,
                    artworkSamples: artworkSamples(for: artworkKey),
                    magnitude: UInt8(clamping: 40 + min(180, $0.playCount * 4))
                )
            })
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
        return result
    }

    private func rewritePlan(for catalogue: SkyCatalogue) throws -> (records: [SkyRecord], deletingIDs: [String]) {
        let records = try makeRecords(catalogue)
        let desiredIDs = Set(records.map(\.id))
        let deletingIDs = try allRecords()
            .filter { $0.kind != .camera && !desiredIDs.contains($0.id) }
            .map(\.id)
        return (records, deletingIDs)
    }

    private func enforceMovement(
        in catalogue: SkyCatalogue,
        from existing: SkyCatalogue,
        affectedIDs: Set<String>
    ) -> SkyCatalogue {
        let oldByID = Dictionary(uniqueKeysWithValues: existing.stars.map { ($0.albumID, $0) })
        var stars = catalogue.stars
        var occupied = Set(stars.map(\.coordinate))
        let directions: [SkyPoint] = [
            .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1), .init(x: -1, y: 1),
            .init(x: -1, y: 0), .init(x: -1, y: -1), .init(x: 0, y: -1), .init(x: 1, y: -1)
        ]
        for index in stars.indices where affectedIDs.contains(stars[index].albumID) {
            let star = stars[index]
            guard let old = oldByID[star.albumID], old.coordinate == star.coordinate,
                  old.artistKey != star.artistKey || old.regionID != star.regionID else { continue }
            occupied.remove(star.coordinate)
            let start = Int(SkyStableHash.value(star.albumID) % UInt64(directions.count))
            var replacement = star.coordinate
            search: for ring in 1...512 {
                for offset in 0..<directions.count {
                    let direction = directions[(start + offset) % directions.count]
                    let distance = Int32(ring) &* SkyComposer.starSpacing
                    let candidate = SkyPoint(
                        x: star.coordinate.x &+ direction.x &* distance,
                        y: star.coordinate.y &+ direction.y &* distance
                    )
                    let clear = occupied.allSatisfy { point in
                        let dx = Int64(candidate.x) - Int64(point.x)
                        let dy = Int64(candidate.y) - Int64(point.y)
                        let minimum = Int64(SkyComposer.starSpacing / 2)
                        return dx * dx + dy * dy >= minimum * minimum
                    }
                    if clear {
                        replacement = candidate
                        break search
                    }
                }
            }
            stars[index] = SkyStar(
                albumID: star.albumID,
                sequence: star.sequence,
                artistKey: star.artistKey,
                artistName: star.artistName,
                regionID: star.regionID,
                coordinate: replacement,
                importedAt: star.importedAt,
                placedAt: star.placedAt,
                isUncharted: star.isUncharted,
                magnitude: star.magnitude,
                title: star.title,
                spectralColor: star.spectralColor
            )
            occupied.insert(replacement)
        }
        var result = catalogue
        result.stars = stars
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
