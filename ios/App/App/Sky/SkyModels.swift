import Foundation

struct SkyPoint: Codable, Equatable, Hashable, Sendable {
    var x: Int32
    var y: Int32

    var radiusSquared: UInt64 {
        UInt64(Int64(x) * Int64(x) + Int64(y) * Int64(y))
    }
}

struct SkyColor: Codable, Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

struct SkyAlbumInput: Equatable, Sendable {
    let id: String
    let sequence: Int64
    let title: String
    let artist: String
    let genre: String
    let importedAt: Date
    let isCompilation: Bool
    let canonicalArtistGenre: String?
    let artworkSamples: [SkyColor]
    let tempo: Int?
    let dynamicRange: Int?
    let magnitude: UInt8

    init(
        id: String,
        sequence: Int64,
        title: String,
        artist: String,
        genre: String,
        importedAt: Date,
        isCompilation: Bool = false,
        canonicalArtistGenre: String? = nil,
        artworkSamples: [SkyColor] = [],
        tempo: Int? = nil,
        dynamicRange: Int? = nil,
        magnitude: UInt8 = 48
    ) {
        self.id = id
        self.sequence = sequence
        self.title = title
        self.artist = artist
        self.genre = genre
        self.importedAt = importedAt
        self.isCompilation = isCompilation
        self.canonicalArtistGenre = canonicalArtistGenre
        self.artworkSamples = artworkSamples
        self.tempo = tempo
        self.dynamicRange = dynamicRange
        self.magnitude = magnitude
    }
}

enum SkyRegionIdentity {
    static let variousArtists = "region:various-artists"
    static let uncharted = "region:uncharted"
}

struct SkyStar: Codable, Equatable, Identifiable, Sendable {
    var id: String { albumID }
    let albumID: String
    let sequence: Int64
    let artistKey: String
    let artistName: String
    let regionID: String
    let coordinate: SkyPoint
    let importedAt: Date
    let placedAt: Date
    let isUncharted: Bool
    let magnitude: UInt8
}

struct SkyFigureSegment: Codable, Equatable, Hashable, Sendable {
    let fromAlbumID: String
    let toAlbumID: String
}

struct SkyConstellation: Codable, Equatable, Identifiable, Sendable {
    var id: String { artistKey }
    let artistKey: String
    let artistName: String
    let regionID: String
    let albumIDs: [String]
    let figureSegments: [SkyFigureSegment]
}

struct SkyRegion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let isUncharted: Bool
    let isVariousArtists: Bool
    let starCount: Int
}

struct PlanetMember: Codable, Equatable, Hashable, Sendable {
    let albumID: String
    let importedAt: Date
}

struct PlanetDescriptor: Codable, Equatable, Sendable {
    static let algorithmVersion = 1

    let algorithm: Int
    let bandColors: [SkyColor]
    let rotationMillis: UInt32
    let turbulence: UInt16
    let hasRings: Bool
}

struct SkyPlanet: Codable, Equatable, Identifiable, Sendable {
    var id: String { "planet:\(index)" }
    var name: String {
        let names = ["Vesper", "Orison", "Caelum", "Lumen", "Nacre", "Aster", "Eidolon", "Vela"]
        return "\(names[Int(seed % UInt64(names.count))]) \(Self.roman(index))"
    }
    var systemName: String { "\(name) System" }
    var albumRange: ClosedRange<Int> {
        let start = (index - 1) * SkyComposer.albumsPerPlanet + 1
        return start...(start + SkyComposer.albumsPerPlanet - 1)
    }
    let index: Int
    let members: [PlanetMember]
    let frontierRadius: UInt32
    let formationTimestamp: Date
    let seed: UInt64
    let coordinate: SkyPoint
    let exclusionRadius: UInt32
    let descriptor: PlanetDescriptor

    func vibrancy(using albums: [SkyAlbumInput]) -> UInt8 {
        let memberIDs = Set(members.map(\.albumID))
        let values = albums.lazy.filter { memberIDs.contains($0.id) }.map { Int($0.magnitude) }
        let total = values.reduce(into: (sum: 0, count: 0)) { result, value in
            result.sum += value
            result.count += 1
        }
        return total.count == 0 ? 48 : UInt8(clamping: total.sum / total.count)
    }

    private static func roman(_ value: Int) -> String {
        let numerals = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = max(1, value)
        var result = ""
        for (number, numeral) in numerals {
            while remaining >= number { result += numeral; remaining -= number }
        }
        return result
    }
}

struct SkyCatalogue: Codable, Equatable, Sendable {
    var regions: [SkyRegion]
    var constellations: [SkyConstellation]
    var stars: [SkyStar]
    var planets: [SkyPlanet]

    static let empty = SkyCatalogue(regions: [], constellations: [], stars: [], planets: [])
}

enum SkyStableHash {
    static func value(_ string: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var result = value &+ 0x9e3779b97f4a7c15
        result = (result ^ (result >> 30)) &* 0xbf58476d1ce4e5b9
        result = (result ^ (result >> 27)) &* 0x94d049bb133111eb
        return result ^ (result >> 31)
    }

    static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
