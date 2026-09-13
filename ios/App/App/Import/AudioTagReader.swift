import AVFoundation
import Foundation

struct AudioTags: Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var year: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var artworkData: Data?

    init(
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        year: String? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artworkData = artworkData
    }

    mutating func fillMissing(from other: AudioTags, includeArtwork: Bool) {
        if title == nil { title = other.title }
        if artist == nil { artist = other.artist }
        if albumArtist == nil { albumArtist = other.albumArtist }
        if album == nil { album = other.album }
        if year == nil { year = other.year }
        if genre == nil { genre = other.genre }
        if trackNumber == nil { trackNumber = other.trackNumber }
        if discNumber == nil { discNumber = other.discNumber }
        if includeArtwork, artworkData == nil { artworkData = other.artworkData }
    }
}

protocol AudioTagReading {
    func read(url: URL, includeArtwork: Bool) async throws -> AudioTags
}

enum AudioTagReaderError: Error, Equatable {
    case unavailable
    case unsupportedFormat
}

final class AudioTagReader: AudioTagReading {
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "wave", "aif", "aiff", "caf"
    ]

    private let fileManager: FileManager
    private let maximumTagBytes: Int
    private let maximumArtworkBytes: Int

    init(
        fileManager: FileManager = .default,
        maximumTagBytes: Int = 3 * 1_024 * 1_024,
        maximumArtworkBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.fileManager = fileManager
        self.maximumTagBytes = maximumTagBytes
        self.maximumArtworkBytes = maximumArtworkBytes
    }

    func read(url: URL, includeArtwork: Bool = false) async throws -> AudioTags {
        guard fileManager.fileExists(atPath: url.path) else { throw AudioTagReaderError.unavailable }
        let fileExtension = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else { throw AudioTagReaderError.unsupportedFormat }

        var tags = await foundationTags(url: url, includeArtwork: includeArtwork)
        let supplemental: AudioTags?
        switch fileExtension {
        case "mp3", "aac": supplemental = try? readID3(url: url, includeArtwork: includeArtwork)
        case "flac": supplemental = try? readFLAC(url: url, includeArtwork: includeArtwork)
        default: supplemental = nil
        }
        if let supplemental { tags.fillMissing(from: supplemental, includeArtwork: includeArtwork) }
        if clean(tags.title) == nil { tags.title = url.deletingPathExtension().lastPathComponent }
        tags.title = clean(tags.title)
        tags.artist = clean(tags.artist)
        tags.albumArtist = clean(tags.albumArtist)
        tags.album = clean(tags.album)
        tags.year = year(tags.year)
        tags.genre = clean(tags.genre)
        if !includeArtwork { tags.artworkData = nil }
        return tags
    }

    private func foundationTags(url: URL, includeArtwork: Bool) async -> AudioTags {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var items: [AVMetadataItem] = []
        do {
            items.append(contentsOf: try await asset.load(.commonMetadata))
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats.prefix(12) {
                items.append(contentsOf: try await asset.loadMetadata(for: format))
            }
        } catch {
            return AudioTags()
        }

        var tags = AudioTags()
        for item in items {
            let identity = [item.commonKey?.rawValue, item.identifier?.rawValue, item.key as? String]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            if includeArtwork, tags.artworkData == nil,
               identity.contains("artwork") || identity.contains("covr") || identity.contains("apic"),
               let data = item.dataValue, data.count <= maximumArtworkBytes {
                tags.artworkData = data
                continue
            }
            guard let text = clean(item.stringValue ?? item.numberValue?.stringValue) else { continue }
            if identity.contains("albumartist") || identity.contains("album_artist") || identity.contains("aart") {
                tags.albumArtist = tags.albumArtist ?? text
            } else if identity.contains("albumname") || identity.contains("talb") || identity.contains("©alb") {
                tags.album = tags.album ?? text
            } else if identity.contains("tracknumber") || identity.contains("trck") {
                tags.trackNumber = tags.trackNumber ?? positiveLeadingInteger(text)
            } else if identity.contains("discnumber") || identity.contains("tpos") || identity.contains("disk") {
                tags.discNumber = tags.discNumber ?? positiveLeadingInteger(text)
            } else if identity.contains("creationdate") || identity.contains("tdrc") || identity.contains("tyer") || identity.contains("©day") {
                tags.year = tags.year ?? year(text)
            } else if identity.contains("genre") || identity.contains("tcon") || identity.contains("©gen") {
                tags.genre = tags.genre ?? text
            } else if identity.contains("title") || identity.contains("tit2") || identity.contains("©nam") {
                tags.title = tags.title ?? text
            } else if identity.contains("artist") || identity.contains("tpe1") || identity.contains("©art") {
                tags.artist = tags.artist ?? text
            }
        }
        return tags
    }

    private func readID3(url: URL, includeArtwork: Bool) throws -> AudioTags {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 10), header.count == 10,
              header.prefix(3) == Data("ID3".utf8), header[3] == 3 || header[3] == 4 else { return AudioTags() }
        let tagSize = syncSafe(header, at: 6)
        guard tagSize > 0, tagSize <= maximumTagBytes,
              let body = try handle.read(upToCount: tagSize), body.count == tagSize else { return AudioTags() }
        let version = header[3]
        var offset = 0
        var tags = AudioTags()
        while offset + 10 <= body.count {
            let idData = body.subdata(in: offset ..< offset + 4)
            guard let id = String(data: idData, encoding: .ascii), id.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil else { break }
            let frameSize = version == 4 ? syncSafe(body, at: offset + 4) : bigEndianInt(body, at: offset + 4)
            offset += 10
            guard frameSize > 0, frameSize <= body.count - offset else { break }
            let payload = body.subdata(in: offset ..< offset + frameSize)
            offset += frameSize
            if id == "APIC", includeArtwork, tags.artworkData == nil {
                tags.artworkData = id3Artwork(payload)
            } else if id.first == "T", payload.count > 1,
                      let text = decodeID3Text(payload[0], payload.dropFirst())?.components(separatedBy: "\0").first.flatMap(clean) {
                switch id {
                case "TIT2": tags.title = tags.title ?? text
                case "TPE1": tags.artist = tags.artist ?? text
                case "TPE2": tags.albumArtist = tags.albumArtist ?? text
                case "TALB": tags.album = tags.album ?? text
                case "TDRC", "TYER": tags.year = tags.year ?? year(text)
                case "TCON": tags.genre = tags.genre ?? text
                case "TRCK": tags.trackNumber = tags.trackNumber ?? positiveLeadingInteger(text)
                case "TPOS": tags.discNumber = tags.discNumber ?? positiveLeadingInteger(text)
                default: break
                }
            }
        }
        return tags
    }

    private func id3Artwork(_ payload: Data) -> Data? {
        guard payload.count > 4 else { return nil }
        let encoding = payload[0]
        guard let mimeEnd = payload[1...].firstIndex(of: 0) else { return nil }
        var offset = mimeEnd + 1
        guard offset < payload.count else { return nil }
        offset += 1
        if encoding == 1 || encoding == 2 {
            while offset + 1 < payload.count, !(payload[offset] == 0 && payload[offset + 1] == 0) { offset += 2 }
            offset += 2
        } else {
            while offset < payload.count, payload[offset] != 0 { offset += 1 }
            offset += 1
        }
        guard offset < payload.count else { return nil }
        let image = payload.subdata(in: offset ..< payload.count)
        return image.count <= maximumArtworkBytes ? image : nil
    }

    private func readFLAC(url: URL, includeArtwork: Bool) throws -> AudioTags {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return AudioTags() }
        var tags = AudioTags()
        var consumed = 4
        var isLast = false
        while !isLast, consumed + 4 <= maximumTagBytes,
              let header = try handle.read(upToCount: 4), header.count == 4 {
            consumed += 4
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7f
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length >= 0, length <= maximumTagBytes - consumed else { break }
            guard let block = try handle.read(upToCount: length), block.count == length else { break }
            consumed += length
            if type == 4 { parseVorbisComments(block, into: &tags) }
            else if type == 6, includeArtwork, tags.artworkData == nil { tags.artworkData = flacArtwork(block) }
        }
        return tags
    }

    private func parseVorbisComments(_ data: Data, into tags: inout AudioTags) {
        var offset = 0
        guard let vendorLength = littleEndianInt(data, at: offset) else { return }
        offset += 4
        guard vendorLength <= data.count - offset else { return }
        offset += vendorLength
        guard let count = littleEndianInt(data, at: offset), count <= 100_000 else { return }
        offset += 4
        for _ in 0 ..< count {
            guard let length = littleEndianInt(data, at: offset) else { return }
            offset += 4
            guard length <= data.count - offset,
                  let value = String(data: data.subdata(in: offset ..< offset + length), encoding: .utf8) else { return }
            offset += length
            let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let text = clean(String(pair[1])) else { continue }
            switch pair[0].uppercased() {
            case "TITLE": tags.title = tags.title ?? text
            case "ARTIST": tags.artist = tags.artist ?? text
            case "ALBUMARTIST", "ALBUM ARTIST": tags.albumArtist = tags.albumArtist ?? text
            case "ALBUM": tags.album = tags.album ?? text
            case "DATE", "YEAR": tags.year = tags.year ?? year(text)
            case "GENRE": tags.genre = tags.genre ?? text
            case "TRACKNUMBER": tags.trackNumber = tags.trackNumber ?? positiveLeadingInteger(text)
            case "DISCNUMBER": tags.discNumber = tags.discNumber ?? positiveLeadingInteger(text)
            default: break
            }
        }
    }

    private func flacArtwork(_ data: Data) -> Data? {
        var offset = 4
        guard let mimeLength = bigEndianOptionalInt(data, at: offset) else { return nil }
        offset += 4 + mimeLength
        guard let descriptionLength = bigEndianOptionalInt(data, at: offset) else { return nil }
        offset += 4 + descriptionLength + 16
        guard let imageLength = bigEndianOptionalInt(data, at: offset), imageLength <= maximumArtworkBytes else { return nil }
        offset += 4
        guard imageLength <= data.count - offset else { return nil }
        return data.subdata(in: offset ..< offset + imageLength)
    }

    private func decodeID3Text(_ encoding: UInt8, _ bytes: Data.SubSequence) -> String? {
        let data = Data(bytes)
        switch encoding {
        case 0: return String(data: data, encoding: .isoLatin1)
        case 1: return String(data: data, encoding: .utf16)
        case 2: return String(data: data, encoding: .utf16BigEndian)
        case 3: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    private func syncSafe(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) & 0x7f) << 21 | (Int(data[offset + 1]) & 0x7f) << 14 |
            (Int(data[offset + 2]) & 0x7f) << 7 | (Int(data[offset + 3]) & 0x7f)
    }

    private func bigEndianInt(_ data: Data, at offset: Int) -> Int {
        bigEndianOptionalInt(data, at: offset) ?? 0
    }

    private func bigEndianOptionalInt(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }

    private func littleEndianInt(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }

    private func positiveLeadingInteger(_ value: String) -> Int? {
        guard let match = value.range(of: #"^\s*(\d+)"#, options: .regularExpression) else { return nil }
        let digits = value[match].trimmingCharacters(in: .whitespaces)
        guard let number = Int(digits), number > 0 else { return nil }
        return number
    }

    private func year(_ value: String?) -> String? {
        guard let value, let range = value.range(of: #"\b\d{4}\b"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
