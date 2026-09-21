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
    var title: String? = nil
    var spectralColor: SkyColor? = nil
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
    var systemName: String { name }
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
    // Optional for safe decoding of existing catalogues. Material generation never
    // changes reward identity, formation context, coordinates or legacy descriptor.
    var material: PlanetMaterialDescriptor? = nil
    var resolvedMaterial: PlanetMaterialDescriptor {
        if let material, material.version >= 3 { return material }
        return .make(worldID: id, seed: seed, index: index)
    }

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

struct PlanetMaterialDescriptor: Codable, Equatable, Sendable {
    enum Family: UInt32, Codable, CaseIterable, Sendable {
        case ocean, storm, glacial, volcanic, ringed, auroral
    }
    let version: Int
    let worldID: String
    let seed: UInt64
    let family: Family
    let palette: [SkyColor]
    let cloudCover: Float
    let roughness: Float
    let atmosphere: Float
    let emission: Float
    let axialTilt: Float
    let rotationRate: Float
    let phase: Float
    let ringExtent: Float
    let ringInclination: Float

    static func make(worldID: String, seed: UInt64, index: Int) -> Self {
        let family = Family(rawValue: UInt32(max(0, index - 1) % 6)) ?? .ocean
        let palettes: [[SkyColor]] = [
            [.init(red: 12, green: 52, blue: 92), .init(red: 36, green: 155, blue: 177), .init(red: 226, green: 235, blue: 224)],
            [.init(red: 99, green: 41, blue: 18), .init(red: 211, green: 142, blue: 64), .init(red: 246, green: 217, blue: 163)],
            [.init(red: 42, green: 94, blue: 140), .init(red: 153, green: 211, blue: 226), .init(red: 237, green: 245, blue: 244)],
            [.init(red: 30, green: 32, blue: 38), .init(red: 77, green: 65, blue: 57), .init(red: 246, green: 126, blue: 34)],
            [.init(red: 72, green: 83, blue: 98), .init(red: 162, green: 178, blue: 184), .init(red: 226, green: 191, blue: 138)],
            [.init(red: 29, green: 34, blue: 87), .init(red: 95, green: 77, blue: 151), .init(red: 70, green: 223, blue: 183)]
        ]
        let i = Int(family.rawValue)
        let phase = Float(SkyStableHash.mix(seed) & 0xffff) / 65535
        return Self(version: 3, worldID: worldID, seed: seed, family: family,
                    palette: palettes[i], cloudCover: [0.55, 0.9, 0.12, 0, 0.3, 0.35][i],
                    roughness: [0.18, 0.9, 0.42, 0.95, 0.75, 0.7][i],
                    atmosphere: [0.23, 0.16, 0.14, 0.06, 0.1, 0.3][i],
                    emission: [0, 0, 0, 0.8, 0, 0.55][i], axialTilt: (phase - 0.5) * 0.9,
                    rotationRate: [0.008, 0.014, 0.003, 0.002, 0.005, -0.006][i],
                    phase: phase * 6.283185, ringExtent: family == .ringed ? 1.62 : 1.08,
                    ringInclination: 0.30 + phase * 0.12)
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
