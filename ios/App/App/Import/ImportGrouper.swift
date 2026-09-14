import Foundation

enum LibraryImportGroupingMode: String, CaseIterable, Equatable {
    case single
    case folder
    case smart
}

struct ImportCandidate {
    let url: URL
    let folder: String
    let folderKey: String
    let batchLabel: String
    let tags: AudioTags
    let selectionIndex: Int
}

struct ImportAlbumFields: Equatable {
    let title: String
    let artist: String
    let year: String?
    let genre: String?
}

struct InferredTrackNumbers: Equatable {
    let disc: Int?
    let track: Int?
}

enum ImportGrouper {
    static func group(_ items: [ImportCandidate], mode: LibraryImportGroupingMode) -> [[ImportCandidate]] {
        guard !items.isEmpty else { return [] }
        switch mode {
        case .folder:
            return stableGroups(items, key: \.folderKey)
        case .single:
            let folderCount = Set(items.map(\.folderKey)).count
            return folderCount > 1 ? stableGroups(items, key: \.folderKey) : [items]
        case .smart:
            return smartGroups(items)
        }
    }

    static func sortAlbumItems(_ items: [ImportCandidate]) -> [ImportCandidate] {
        items.sorted { left, right in
            let leftInferred = trackNumbers(from: left.url.lastPathComponent)
            let rightInferred = trackNumbers(from: right.url.lastPathComponent)
            let leftDisc = left.tags.discNumber ?? leftInferred.disc ?? 0
            let rightDisc = right.tags.discNumber ?? rightInferred.disc ?? 0
            if leftDisc != rightDisc { return leftDisc < rightDisc }

            let leftTrack = left.tags.trackNumber ?? leftInferred.track
            let rightTrack = right.tags.trackNumber ?? rightInferred.track
            switch (leftTrack, rightTrack) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let comparison = left.url.lastPathComponent.localizedStandardCompare(right.url.lastPathComponent)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.selectionIndex < right.selectionIndex
            }
        }
    }

    static func albumFields(for items: [ImportCandidate], batchLabel: String) -> ImportAlbumFields {
        let album = majority(items.compactMap { clean($0.tags.album) })
        let albumArtist = majority(items.compactMap { clean($0.tags.albumArtist) })
        let artist = albumArtist ?? majority(items.compactMap { clean($0.tags.artist) }) ?? "Unknown Artist"
        let fallback = clean(batchLabel) ?? majority(items.compactMap { clean($0.folder) }) ?? "Untitled Album"
        return ImportAlbumFields(
            title: album ?? fallback,
            artist: artist,
            year: majority(items.compactMap { clean($0.tags.year) }),
            genre: majority(items.compactMap { clean($0.tags.genre) })
        )
    }

    static func isDuplicate(
        existingTitle: String,
        existingArtist: String,
        existingTrackCount: Int,
        candidate: ImportAlbumFields,
        candidateTrackCount: Int
    ) -> Bool {
        normalizedAlbum(existingTitle) == normalizedAlbum(candidate.title) &&
            normalizedPerson(existingArtist) == normalizedPerson(candidate.artist) &&
            existingTrackCount == candidateTrackCount
    }

    static func trackNumbers(from filename: String) -> InferredTrackNumbers {
        let stem = (filename as NSString).deletingPathExtension
        if let groups = captures(#"^\s*[\[(]?\s*(\d+)\s*[-.]\s*(\d+)\s*[\])]?"#, in: stem),
           let disc = Int(groups[0]), let track = Int(groups[1]), disc > 0, track > 0 {
            return InferredTrackNumbers(disc: disc, track: track)
        }
        if let groups = captures(#"^\s*([A-Za-z])(\d+)\b"#, in: stem),
           let scalar = groups[0].uppercased().unicodeScalars.first,
           let track = Int(groups[1]), track > 0 {
            let disc = Int(scalar.value - UnicodeScalar("A").value) + 1
            return InferredTrackNumbers(disc: disc, track: track)
        }
        if let groups = captures(#"^\s*[\[(]?\s*(\d+)\b"#, in: stem),
           let track = Int(groups[0]), track > 0 {
            return InferredTrackNumbers(disc: nil, track: track)
        }
        return InferredTrackNumbers(disc: nil, track: nil)
    }

    static func normalizedAlbum(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(
                of: #"\s*[\[(](?:deluxe(?:\s+edition)?|expanded(?:\s+edition)?|remaster(?:ed)?(?:\s+edition)?|anniversary(?:\s+edition)?|bonus(?:\s+tracks?)?|special(?:\s+edition)?|disc\s*\d+|cd\s*\d+)[\])]\s*"#,
                with: " ", options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"\b(?:disc|cd)\s*\d+\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func normalizedPerson(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func smartGroups(_ items: [ImportCandidate]) -> [[ImportCandidate]] {
        var groups: [[ImportCandidate]] = []
        var keys: [(album: String, artist: String)] = []
        var directoryOnly: [ImportCandidate] = []

        for item in items {
            guard let album = clean(item.tags.album) else {
                directoryOnly.append(item)
                continue
            }
            let albumKey = normalizedAlbum(album)
            let artistKey = normalizedPerson(item.tags.albumArtist ?? item.tags.artist ?? "")
            let index = keys.firstIndex {
                $0.artist == artistKey && ($0.album == albumKey || $0.album.contains(albumKey) || albumKey.contains($0.album))
            }
            if let index { groups[index].append(item) }
            else {
                keys.append((albumKey, artistKey))
                groups.append([item])
            }
        }

        for item in directoryOnly {
            let matching = groups.indices.filter { index in
                groups[index].contains { $0.folderKey == item.folderKey }
            }
            if matching.count == 1 { groups[matching[0]].append(item) }
            else if let folderIndex = groups.firstIndex(where: { $0.first?.folderKey == item.folderKey }) {
                groups[folderIndex].append(item)
            } else {
                keys.append(("", ""))
                groups.append([item])
            }
        }
        return groups
    }

    private static func stableGroups(
        _ items: [ImportCandidate],
        key: KeyPath<ImportCandidate, String>
    ) -> [[ImportCandidate]] {
        var order: [String] = []
        var values: [String: [ImportCandidate]] = [:]
        for item in items {
            let value = item[keyPath: key]
            if values[value] == nil { order.append(value); values[value] = [] }
            values[value, default: []].append(item)
        }
        return order.compactMap { values[$0] }
    }

    private static func majority(_ values: [String]) -> String? {
        var counts: [String: (count: Int, first: Int, value: String)] = [:]
        for (index, value) in values.enumerated() {
            let key = normalized(value)
            guard !key.isEmpty else { continue }
            if let current = counts[key] { counts[key] = (current.count + 1, current.first, current.value) }
            else { counts[key] = (1, index, value) }
        }
        return counts.values.sorted {
            $0.count == $1.count ? $0.first < $1.first : $0.count > $1.count
        }.first?.value
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}
