import Foundation

struct CatalogAlbum: Codable, Equatable, Identifiable {
    let id: String
    var sequence: Int64
    var title: String
    var artist: String
    var year: String
    var genre: String
    var artworkKey: String?
    var importedAt: Date
    var updatedAt: Date
}

struct CatalogTrack: Codable, Equatable, Identifiable {
    let id: String
    var albumID: String
    var sequence: Int
    var discNumber: Int?
    var trackNumber: Int?
    var title: String
    var artist: String
    var duration: TimeInterval?
    var byteCount: Int64
    var mediaReference: MediaReference
    var importedAt: Date
}

struct CatalogAlbumSummary: Codable, Equatable, Identifiable {
    let id: String
    let sequence: Int64
    let title: String
    let artist: String
    let year: String
    let genre: String
    let artworkKey: String?
    let trackCount: Int
    let playCount: Int64
    let lastPlayedAt: Date?
    let importedAt: Date
}

struct CatalogPlaylist: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

struct CatalogPlaylistItem: Codable, Equatable, Identifiable {
    var id: String { "\(playlistID):\(position)" }
    let playlistID: String
    let position: Int
    let trackID: String
    let albumID: String
    let trackTitle: String
    let albumTitle: String
    let artist: String
}

struct CatalogListeningState: Codable, Equatable {
    let trackID: String
    let playCount: Int64
    let completedCount: Int64
    let lastPosition: TimeInterval
    let lastPlayedAt: Date?
}

enum SkyRecordKind: String, Codable, CaseIterable {
    case region
    case constellation
    case star
    case planet
    case camera
}

struct SkyRecord: Codable, Equatable, Identifiable {
    let id: String
    let kind: SkyRecordKind
    let sequence: Int64
    let payload: Data
    let updatedAt: Date
}

enum MigrationStageStatus: String, Codable {
    case pending
    case materializing
    case complete
    case failed
}

struct MigrationStageRecord: Codable, Equatable, Identifiable {
    var id: String { "\(sourceStore):\(sourceID)" }
    let sourceStore: String
    let sourceID: String
    let status: MigrationStageStatus
    let payload: Data
    let updatedAt: Date
}

enum CatalogAlbumSort: Equatable {
    case recentlyAdded
    case artist
    case title
    case year
    case mostPlayed
}

struct CatalogSearchResults: Equatable {
    struct TrackHit: Equatable, Identifiable {
        var id: String { trackID }
        let trackID: String
        let albumID: String
        let trackTitle: String
        let albumTitle: String
        let artist: String
    }

    let albums: [CatalogAlbumSummary]
    let artists: [String]
    let tracks: [TrackHit]
}

struct CatalogSnapshot: Equatable {
    let albums: [CatalogAlbumSummary]
    let playlists: [CatalogPlaylist]
}
