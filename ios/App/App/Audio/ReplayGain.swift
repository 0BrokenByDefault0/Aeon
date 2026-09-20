import Foundation

struct ReplayGainValues: Codable, Equatable {
    let trackGainDB: Double?
    let albumGainDB: Double?
    let trackPeak: Double?
    let albumPeak: Double?

    static let empty = ReplayGainValues(
        trackGainDB: nil,
        albumGainDB: nil,
        trackPeak: nil,
        albumPeak: nil
    )

    var isEmpty: Bool {
        trackGainDB == nil && albumGainDB == nil && trackPeak == nil && albumPeak == nil
    }

    static func parse(fields: [String: String]) -> ReplayGainValues {
        let normalized = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.uppercased(), $0.value) })
        return ReplayGainValues(
            trackGainDB: decimal(normalized["REPLAYGAIN_TRACK_GAIN"], strippingDB: true),
            albumGainDB: decimal(normalized["REPLAYGAIN_ALBUM_GAIN"], strippingDB: true),
            trackPeak: decimal(normalized["REPLAYGAIN_TRACK_PEAK"], strippingDB: false),
            albumPeak: decimal(normalized["REPLAYGAIN_ALBUM_PEAK"], strippingDB: false)
        )
    }

    private static func decimal(_ raw: String?, strippingDB: Bool) -> Double? {
        guard var raw else { return nil }
        if strippingDB { raw = raw.replacingOccurrences(of: "dB", with: "", options: .caseInsensitive) }
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            return nil
        }
        return value
    }
}

enum ReplayGainMetadataReader {
    private static let keys = Set([
        "REPLAYGAIN_TRACK_GAIN",
        "REPLAYGAIN_ALBUM_GAIN",
        "REPLAYGAIN_TRACK_PEAK",
        "REPLAYGAIN_ALBUM_PEAK"
    ])

    static func read(url: URL, maximumBytes: Int = 4 * 1_024 * 1_024) -> ReplayGainValues {
        guard maximumBytes >= 10, let handle = try? FileHandle(forReadingFrom: url) else { return .empty }
        defer { try? handle.close() }
        guard let signature = try? handle.read(upToCount: 10), signature.count >= 4 else { return .empty }
        try? handle.seek(toOffset: 0)
        if signature.prefix(3) == Data("ID3".utf8) {
            return readID3(handle: handle, maximumBytes: maximumBytes)
        }
        if signature.prefix(4) == Data("fLaC".utf8) {
            return readFLAC(handle: handle, maximumBytes: maximumBytes)
        }
        // MP4 families carry the tags as iTunes freeform atoms. m4a, aac and alac are a
        // third of the supported extensions and previously returned .empty every time,
        // so an Apple-ecosystem library got no loudness matching at all.
        if signature.count >= 8, Data(signature[4 ..< 8]) == Data("ftyp".utf8) {
            return readMP4(handle: handle, maximumBytes: maximumBytes)
        }
        return .empty
    }

    private static let mp4Containers: Set<Data> = Set(
        ["moov", "udta", "ilst", "----"].map { Data($0.utf8) }
    )

    private static func readMP4(handle: FileHandle, maximumBytes: Int) -> ReplayGainValues {
        guard let moov = locateMP4Moov(handle: handle, maximumBytes: maximumBytes) else { return .empty }
        var fields: [String: String] = [:]
        collectMP4Freeform(in: moov, into: &fields)
        return ReplayGainValues.parse(fields: fields)
    }

    private static func locateMP4Moov(handle: FileHandle, maximumBytes: Int) -> Data? {
        var offset: UInt64 = 0
        // A malformed file must not spin here; real files reach moov within a few atoms.
        for _ in 0 ..< 64 {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
            let size = bigEndian(header, at: 0)
            // size 0 means "to end of file" and 1 means a 64-bit size follows; neither is
            // worth supporting for a metadata probe.
            guard size >= 8, size <= maximumBytes else { return nil }
            if Data(header.dropFirst(4)) == Data("moov".utf8) {
                return try? handle.read(upToCount: size - 8)
            }
            offset += UInt64(size)
        }
        return nil
    }

    /// Walk `moov` for `----` freeform atoms, pairing each `name` with the `data` that
    /// follows it inside the same container.
    private static func collectMP4Freeform(in payload: Data, into fields: inout [String: String], depth: Int = 0) {
        guard depth < 8 else { return }
        var offset = 0
        var pendingKey: String?
        while offset + 8 <= payload.count {
            let size = bigEndian(payload, at: offset)
            guard size >= 8, size <= payload.count - offset else { return }
            let type = Data(payload[(offset + 4) ..< (offset + 8)])
            let body = Data(payload[(offset + 8) ..< (offset + size)])
            if type == Data("meta".utf8) {
                // `meta` is a full box: four bytes of version and flags precede children.
                if body.count > 4 { collectMP4Freeform(in: Data(body.dropFirst(4)), into: &fields, depth: depth + 1) }
            } else if mp4Containers.contains(type) {
                collectMP4Freeform(in: body, into: &fields, depth: depth + 1)
            } else if type == Data("name".utf8), body.count > 4 {
                pendingKey = String(data: Data(body.dropFirst(4)), encoding: .utf8)?.uppercased()
            } else if type == Data("data".utf8), body.count > 8 {
                // data payload: 4 bytes type indicator, 4 bytes locale, then the value.
                if let key = pendingKey, keys.contains(key),
                   let value = String(data: Data(body.dropFirst(8)), encoding: .utf8) {
                    fields[key] = value
                }
                pendingKey = nil
            }
            offset += size
        }
    }

    private static func readID3(handle: FileHandle, maximumBytes: Int) -> ReplayGainValues {
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header[3] == 3 || header[3] == 4 else { return .empty }
        let size = syncSafe(header, at: 6)
        guard size > 0, size <= maximumBytes - 10,
              let payload = try? handle.read(upToCount: size), payload.count == size else { return .empty }
        var offset = 0
        var fields: [String: String] = [:]
        while offset + 10 <= payload.count {
            guard let frameID = String(data: payload[offset ..< offset + 4], encoding: .ascii),
                  frameID.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else {
                break
            }
            let frameSize = header[3] == 4 ? syncSafe(payload, at: offset + 4) : bigEndian(payload, at: offset + 4)
            offset += 10
            guard frameSize > 0, frameSize <= payload.count - offset else { break }
            defer { offset += frameSize }
            guard frameID == "TXXX", frameSize > 2 else { continue }
            let frame = payload[offset ..< offset + frameSize]
            guard let text = decodeText(encoding: frame[frame.startIndex], data: Data(frame.dropFirst())) else { continue }
            let parts = text.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if keys.contains(key) { fields[key] = parts[1] }
        }
        return ReplayGainValues.parse(fields: fields)
    }

    private static func readFLAC(handle: FileHandle, maximumBytes: Int) -> ReplayGainValues {
        guard (try? handle.read(upToCount: 4)) == Data("fLaC".utf8) else { return .empty }
        var consumed = 4
        var last = false
        while !last, consumed + 4 <= maximumBytes,
              let header = try? handle.read(upToCount: 4), header.count == 4 {
            consumed += 4
            last = header[0] & 0x80 != 0
            let type = header[0] & 0x7f
            let size = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard size <= maximumBytes - consumed,
                  let block = try? handle.read(upToCount: size), block.count == size else { break }
            consumed += size
            if type == 4 { return parseVorbisComments(block) }
        }
        return .empty
    }

    private static func parseVorbisComments(_ data: Data) -> ReplayGainValues {
        var offset = 0
        guard let vendorSize = littleEndian(data, at: offset) else { return .empty }
        offset += 4
        guard vendorSize <= data.count - offset else { return .empty }
        offset += vendorSize
        guard let count = littleEndian(data, at: offset), count <= 100_000 else { return .empty }
        offset += 4
        var fields: [String: String] = [:]
        for _ in 0 ..< count {
            guard let size = littleEndian(data, at: offset) else { break }
            offset += 4
            guard size <= data.count - offset,
                  let field = String(data: data[offset ..< offset + size], encoding: .utf8) else { break }
            offset += size
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].uppercased()
            if keys.contains(key) { fields[key] = String(pair[1]) }
        }
        return ReplayGainValues.parse(fields: fields)
    }

    private static func decodeText(encoding: UInt8, data: Data) -> String? {
        switch encoding {
        case 0: return String(data: data, encoding: .isoLatin1)
        case 1: return String(data: data, encoding: .unicode)
        case 2: return String(data: data, encoding: .utf16BigEndian)
        case 3: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    private static func syncSafe(_ data: Data, at offset: Int) -> Int {
        guard data.count >= offset + 4 else { return 0 }
        return (Int(data[offset]) << 21) | (Int(data[offset + 1]) << 14) |
            (Int(data[offset + 2]) << 7) | Int(data[offset + 3])
    }

    private static func bigEndian(_ data: Data, at offset: Int) -> Int {
        guard data.count >= offset + 4 else { return 0 }
        return Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 |
            Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }

    private static func littleEndian(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 |
            Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }
}

func replayGainDB(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Double {
    let selectedGain: Double?
    switch mode {
    case .off:
        return 0
    case .album:
        selectedGain = values.albumGainDB
    case .track:
        selectedGain = values.trackGainDB
    }

    guard let selectedGain, selectedGain.isFinite, preampDB.isFinite else { return 0 }
    let combinedGain = selectedGain + preampDB
    return combinedGain.isFinite ? combinedGain : 0
}

func replayGainScalar(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Float {
    let db = replayGainDB(mode: mode, values: values, preampDB: preampDB)
    let scalar = Float(pow(10.0, db / 20.0))
    return scalar.isFinite && scalar > 0 ? scalar : 1
}

func replayGainPeakWarning(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Bool {
    let peak: Double?
    switch mode {
    case .off: return false
    case .album: peak = values.albumPeak
    case .track: peak = values.trackPeak
    }
    guard let peak, peak.isFinite, peak > 0 else { return false }
    return peak * Double(replayGainScalar(mode: mode, values: values, preampDB: preampDB)) > 1
}
