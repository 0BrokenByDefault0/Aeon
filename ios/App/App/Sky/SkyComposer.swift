import Foundation

enum SkyComposerError: Error, Equatable {
    case duplicateAlbum(String)
    case invalidAlbum(String)
}

struct SkyComposer {
    static let albumsPerPlanet = 20
    static let starSpacing: Int32 = 64
    static let planetExclusionRadius: UInt32 = 42

    func compose(albums: [SkyAlbumInput], preserving existing: SkyCatalogue = .empty) throws -> SkyCatalogue {
        let ordered = albums.sorted(by: Self.albumOrder)
        try validate(ordered)
        let existingByAlbum = Dictionary(uniqueKeysWithValues: existing.stars.map { ($0.albumID, $0) })
        let placements = regionPlacements(for: ordered)
        var stars = existing.stars
        var occupied = SpatialIndex(points: existing.stars.filter { !$0.isUncharted }.map(\.coordinate))
        let existingAnchors = Dictionary(grouping: existing.stars, by: \.artistKey).compactMapValues(\.last)
        var latestStars = existingAnchors

        for album in ordered where existingByAlbum[album.id] == nil {
            let artistKey = Self.artistKey(for: album)
            let placement = placements[artistKey] ?? .uncharted
            let coordinate: SkyPoint
            if placement == .uncharted {
                coordinate = unchartedCoordinate(albumID: album.id)
            } else if let prior = existingAnchors[artistKey] ?? latestStars[artistKey] {
                coordinate = nearbyCoordinate(albumID: album.id, anchor: prior.coordinate, occupied: &occupied)
            } else {
                coordinate = outwardCoordinate(album: album, occupied: &occupied)
            }
            stars.append(SkyStar(
                albumID: album.id,
                sequence: album.sequence,
                artistKey: artistKey,
                artistName: album.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                regionID: placement.regionID,
                coordinate: coordinate,
                importedAt: album.importedAt,
                placedAt: album.importedAt,
                isUncharted: placement == .uncharted,
                magnitude: placement == .uncharted ? min(album.magnitude, 40) : album.magnitude
            ))
            latestStars[artistKey] = stars.last
        }
        stars.sort { lhs, rhs in
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt < rhs.importedAt }
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.albumID < rhs.albumID
        }

        let constellations = makeConstellations(stars: stars)
        let regions = makeRegions(stars: stars)
        let planets = makePlanets(albums: ordered, stars: stars, existing: existing.planets)
        return SkyCatalogue(regions: regions, constellations: constellations, stars: stars, planets: planets)
    }

    private enum Placement: Equatable {
        case region(String)
        case variousArtists
        case uncharted

        var regionID: String {
            switch self {
            case .region(let id): return id
            case .variousArtists: return SkyRegionIdentity.variousArtists
            case .uncharted: return SkyRegionIdentity.uncharted
            }
        }
    }

    private func validate(_ albums: [SkyAlbumInput]) throws {
        var ids = Set<String>()
        for album in albums {
            guard !album.id.isEmpty, album.id.utf8.count <= 512, album.sequence > 0 else {
                throw SkyComposerError.invalidAlbum(album.id)
            }
            guard ids.insert(album.id).inserted else { throw SkyComposerError.duplicateAlbum(album.id) }
        }
    }

    private func regionPlacements(for albums: [SkyAlbumInput]) -> [String: Placement] {
        Dictionary(grouping: albums, by: Self.artistKey).mapValues { values in
            if values.contains(where: Self.isVariousArtists) {
                return .variousArtists
            }
            let tagged = values.compactMap { album -> (String, Date, Int64)? in
                let key = SkyStableHash.normalized(album.genre)
                return key.isEmpty ? nil : (key, album.importedAt, album.sequence)
            }
            guard let first = tagged.first else { return .uncharted }
            let counts = Dictionary(grouping: tagged, by: \.0).mapValues(\.count)
            if counts.count > 1,
               let canonical = values.lazy.compactMap(\.canonicalArtistGenre)
                .map(SkyStableHash.normalized).first(where: { !$0.isEmpty }) {
                return .region(Self.regionID(canonical))
            }
            let maximum = counts.values.max()
            let winner = tagged.filter { counts[$0.0] == maximum }.min {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                return $0.0 < $1.0
            } ?? first
            return .region(Self.regionID(winner.0))
        }
    }

    private func outwardCoordinate(album: SkyAlbumInput, occupied: inout SpatialIndex) -> SkyPoint {
        let start = max(1, Int(album.sequence))
        for attempt in 0..<100_000 {
            var point = Self.squareSpiral(index: start + attempt)
            let orientation = Int(SkyStableHash.value(Self.artistKey(for: album)) & 7)
            point = Self.orient(point, orientation: orientation)
            point = SkyPoint(x: point.x * Self.starSpacing, y: point.y * Self.starSpacing)
            if occupied.insertIfClear(point, minimumDistance: Self.starSpacing / 2) { return point }
        }
        preconditionFailure("Deterministic sky placement exhausted")
    }

    private func nearbyCoordinate(albumID: String, anchor: SkyPoint, occupied: inout SpatialIndex) -> SkyPoint {
        let start = Int(SkyStableHash.value(albumID) % 32) + 1
        for attempt in 0..<1_024 {
            let offset = Self.squareSpiral(index: start + attempt)
            let point = SkyPoint(
                x: anchor.x &+ offset.x &* (Self.starSpacing / 2),
                y: anchor.y &+ offset.y &* (Self.starSpacing / 2)
            )
            if occupied.insertIfClear(point, minimumDistance: Self.starSpacing / 2) { return point }
        }
        preconditionFailure("Deterministic constellation placement exhausted")
    }

    private func unchartedCoordinate(albumID: String) -> SkyPoint {
        let first = SkyStableHash.mix(SkyStableHash.value(albumID))
        let second = SkyStableHash.mix(first)
        return SkyPoint(
            x: Int32(Int64(first % 7_001) - 3_500),
            y: Int32(Int64(second % 2_001) - 7_000)
        )
    }

    private func makeConstellations(stars: [SkyStar]) -> [SkyConstellation] {
        Dictionary(grouping: stars.filter { !$0.isUncharted && $0.regionID != SkyRegionIdentity.variousArtists }, by: \.artistKey)
            .values
            .compactMap { unordered in
                let values = unordered.sorted { $0.sequence == $1.sequence ? $0.albumID < $1.albumID : $0.sequence < $1.sequence }
                guard values.count >= 2, let first = values.first else { return nil }
                return SkyConstellation(
                    artistKey: first.artistKey,
                    artistName: first.artistName,
                    regionID: first.regionID,
                    albumIDs: values.map(\.albumID),
                    figureSegments: zip(values, values.dropFirst()).map {
                        SkyFigureSegment(fromAlbumID: $0.albumID, toAlbumID: $1.albumID)
                    }
                )
            }
            .sorted { $0.artistKey < $1.artistKey }
    }

    private func makeRegions(stars: [SkyStar]) -> [SkyRegion] {
        Dictionary(grouping: stars, by: \.regionID).map { id, values in
            let name: String
            if id == SkyRegionIdentity.uncharted { name = "Uncharted" }
            else if id == SkyRegionIdentity.variousArtists { name = "Various Artists" }
            else { name = id.dropFirst("region:".count).replacingOccurrences(of: "-", with: " ").capitalized }
            return SkyRegion(
                id: id,
                name: name,
                isUncharted: id == SkyRegionIdentity.uncharted,
                isVariousArtists: id == SkyRegionIdentity.variousArtists,
                starCount: values.count
            )
        }.sorted { $0.id < $1.id }
    }

    private func makePlanets(albums: [SkyAlbumInput], stars: [SkyStar], existing: [SkyPlanet]) -> [SkyPlanet] {
        var planets = existing.sorted { $0.index < $1.index }
        let assigned = Set(existing.flatMap { $0.members.map(\.albumID) })
        let available = albums.filter { !assigned.contains($0.id) }
        var cursor = 0
        while cursor + Self.albumsPerPlanet <= available.count {
            let cohort = Array(available[cursor..<(cursor + Self.albumsPerPlanet)])
            let index = (planets.last?.index ?? 0) + 1
            let formation = cohort.last!.importedAt
            let frontierSquared = stars.lazy
                .filter { $0.importedAt <= formation }
                .map { $0.coordinate.radiusSquared }
                .max() ?? 0
            let frontier = UInt32(min(UInt64(UInt32.max), Self.integerSquareRoot(frontierSquared)))
            let seedText = cohort.map(\.id).joined(separator: "\u{1f}") + "#\(index)"
            let seed = SkyStableHash.mix(SkyStableHash.value(seedText))
            let descriptor = planetDescriptor(cohort: cohort, seed: seed)
            let coordinate = planetCoordinate(
                seed: seed,
                frontier: frontier,
                existing: planets
            )
            planets.append(SkyPlanet(
                index: index,
                members: cohort.map { PlanetMember(albumID: $0.id, importedAt: $0.importedAt) },
                frontierRadius: frontier,
                formationTimestamp: formation,
                seed: seed,
                coordinate: coordinate,
                exclusionRadius: Self.planetExclusionRadius,
                descriptor: descriptor
            ))
            cursor += Self.albumsPerPlanet
        }
        return planets
    }

    private func planetDescriptor(cohort: [SkyAlbumInput], seed: UInt64) -> PlanetDescriptor {
        let samples = cohort.flatMap(\.artworkSamples)
        let colors: [SkyColor]
        if samples.isEmpty {
            colors = (0..<3).map { index in
                let value = SkyStableHash.mix(seed &+ UInt64(index))
                return SkyColor(
                    red: Self.quantize(UInt8(truncatingIfNeeded: value >> 16)),
                    green: Self.quantize(UInt8(truncatingIfNeeded: value >> 24)),
                    blue: Self.quantize(UInt8(truncatingIfNeeded: value >> 32))
                )
            }
        } else {
            let stride = max(1, samples.count / 3)
            colors = (0..<3).map { offset in
                let group = Swift.stride(from: offset, to: samples.count, by: stride).prefix(8).map { samples[$0] }
                let count = max(1, group.count)
                let red = group.reduce(0) { partial, color in partial + Int(color.red) }
                let green = group.reduce(0) { partial, color in partial + Int(color.green) }
                let blue = group.reduce(0) { partial, color in partial + Int(color.blue) }
                return SkyColor(
                    red: Self.quantize(UInt8(red / count)),
                    green: Self.quantize(UInt8(green / count)),
                    blue: Self.quantize(UInt8(blue / count))
                )
            }
        }
        let tempos = cohort.compactMap(\.tempo).filter { (20...400).contains($0) }
        let tempo = tempos.isEmpty ? 45 + Int(seed % 120) : tempos.reduce(0, +) / tempos.count
        let dynamics = cohort.compactMap(\.dynamicRange).filter { (0...100).contains($0) }
        let turbulence = dynamics.isEmpty ? UInt16(128 + seed % 640) : UInt16(dynamics.reduce(0, +) * 10 / dynamics.count)
        let genres = Set(cohort.map { SkyStableHash.normalized($0.genre) }.filter { !$0.isEmpty })
        return PlanetDescriptor(
            algorithm: PlanetDescriptor.algorithmVersion,
            bandColors: colors,
            rotationMillis: UInt32(max(600, 240_000 / max(1, tempo))),
            turbulence: turbulence,
            hasRings: genres.count == 1 && cohort.allSatisfy { !SkyStableHash.normalized($0.genre).isEmpty }
        )
    }

    private func planetCoordinate(
        seed: UInt64,
        frontier: UInt32,
        existing: [SkyPlanet]
    ) -> SkyPoint {
        let directions: [SkyPoint] = [
            .init(x: 1024, y: 0), .init(x: 946, y: 392), .init(x: 724, y: 724), .init(x: 392, y: 946),
            .init(x: 0, y: 1024), .init(x: -392, y: 946), .init(x: -724, y: 724), .init(x: -946, y: 392),
            .init(x: -1024, y: 0), .init(x: -946, y: -392), .init(x: -724, y: -724), .init(x: -392, y: -946),
            .init(x: 0, y: -1024), .init(x: 392, y: -946), .init(x: 724, y: -724), .init(x: 946, y: -392)
        ]
        for attempt in 0..<4_096 {
            let direction = directions[Int((seed &+ UInt64(attempt * 5)) % UInt64(directions.count))]
            let radius = Int64(frontier) + 96 + Int64(attempt / directions.count) * 96
            let point = SkyPoint(x: Int32(Int64(direction.x) * radius / 1024), y: Int32(Int64(direction.y) * radius / 1024))
            let clearOfFrontier = Self.integerSquareRoot(point.radiusSquared) >= UInt64(frontier) + UInt64(Self.planetExclusionRadius)
            let clearOfPlanets = existing.allSatisfy {
                Self.distanceSquared(point, $0.coordinate) > UInt64($0.exclusionRadius + Self.planetExclusionRadius) * UInt64($0.exclusionRadius + Self.planetExclusionRadius)
            }
            if clearOfFrontier && clearOfPlanets { return point }
        }
        preconditionFailure("Deterministic planet placement exhausted")
    }

    static func artistKey(for album: SkyAlbumInput) -> String {
        if isVariousArtists(album) { return "artist:various-artists" }
        let normalized = SkyStableHash.normalized(album.artist)
        return "artist:" + (normalized.isEmpty ? "unknown:\(album.id)" : slug(normalized))
    }

    private static func isVariousArtists(_ album: SkyAlbumInput) -> Bool {
        album.isCompilation || ["various artists", "various", "va"].contains(SkyStableHash.normalized(album.artist))
    }

    private static func regionID(_ normalizedGenre: String) -> String { "region:" + slug(normalizedGenre) }

    private static func slug(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        return String(scalars).split(separator: "-").joined(separator: "-")
    }

    private static func albumOrder(_ lhs: SkyAlbumInput, _ rhs: SkyAlbumInput) -> Bool {
        if lhs.importedAt != rhs.importedAt { return lhs.importedAt < rhs.importedAt }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id < rhs.id
    }

    private static func quantize(_ value: UInt8) -> UInt8 { UInt8((Int(value) / 32) * 32) }

    private static func squareSpiral(index: Int) -> SkyPoint {
        guard index > 0 else { return SkyPoint(x: 0, y: 0) }
        var ring = 1
        while (2 * ring + 1) * (2 * ring + 1) <= index { ring += 1 }
        let maximum = (2 * ring + 1) * (2 * ring + 1) - 1
        let side = 2 * ring
        let offset = maximum - index
        switch offset / side {
        case 0: return SkyPoint(x: Int32(ring - offset), y: Int32(-ring))
        case 1: return SkyPoint(x: Int32(-ring), y: Int32(-ring + offset - side))
        case 2: return SkyPoint(x: Int32(-ring + offset - side * 2), y: Int32(ring))
        default: return SkyPoint(x: Int32(ring), y: Int32(ring - offset + side * 3))
        }
    }

    private static func orient(_ point: SkyPoint, orientation: Int) -> SkyPoint {
        switch orientation & 7 {
        case 0: return point
        case 1: return SkyPoint(x: -point.y, y: point.x)
        case 2: return SkyPoint(x: -point.x, y: -point.y)
        case 3: return SkyPoint(x: point.y, y: -point.x)
        case 4: return SkyPoint(x: -point.x, y: point.y)
        case 5: return SkyPoint(x: point.x, y: -point.y)
        case 6: return SkyPoint(x: point.y, y: point.x)
        default: return SkyPoint(x: -point.y, y: -point.x)
        }
    }

    private static func integerSquareRoot(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return value }
        var low: UInt64 = 1
        var high = min(value, UInt64(UInt32.max))
        while low <= high {
            let middle = low + (high - low) / 2
            if middle <= value / middle { low = middle + 1 } else { high = middle - 1 }
        }
        return high
    }

    private static func distanceSquared(_ lhs: SkyPoint, _ rhs: SkyPoint) -> UInt64 {
        let dx = Int64(lhs.x) - Int64(rhs.x)
        let dy = Int64(lhs.y) - Int64(rhs.y)
        return UInt64(dx * dx + dy * dy)
    }

    private struct SpatialIndex {
        private let cell: Int32 = 64
        private var buckets: [Int64: [SkyPoint]] = [:]

        init(points: [SkyPoint]) { points.forEach { insert($0) } }

        mutating func insertIfClear(_ point: SkyPoint, minimumDistance: Int32) -> Bool {
            let x = floorDivide(point.x, cell)
            let y = floorDivide(point.y, cell)
            let minimumSquared = Int64(minimumDistance) * Int64(minimumDistance)
            for nearY in (y - 1)...(y + 1) {
                for nearX in (x - 1)...(x + 1) {
                    for other in buckets[key(x: nearX, y: nearY)] ?? [] {
                        let dx = Int64(point.x) - Int64(other.x)
                        let dy = Int64(point.y) - Int64(other.y)
                        if dx * dx + dy * dy < minimumSquared { return false }
                    }
                }
            }
            insert(point)
            return true
        }

        private mutating func insert(_ point: SkyPoint) {
            let x = floorDivide(point.x, cell)
            let y = floorDivide(point.y, cell)
            buckets[key(x: x, y: y), default: []].append(point)
        }

        private func floorDivide(_ value: Int32, _ divisor: Int32) -> Int32 {
            value >= 0 ? value / divisor : (value - divisor + 1) / divisor
        }

        private func key(x: Int32, y: Int32) -> Int64 {
            (Int64(x) << 32) ^ Int64(UInt32(bitPattern: y))
        }
    }
}
