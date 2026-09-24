import Foundation

/// One line group of an extended M3U playlist. `location` is relative to the app's
/// Documents folder when the track lives in Files; `trackID` lets Aeon itself restore
/// a playlist exactly, while other players fall back to the path and EXTINF line.
struct PlaylistM3UEntry: Equatable {
    var trackID: String?
    var title: String
    var artist: String
    var duration: TimeInterval?
    var documentsRelativePath: String?
}

struct PlaylistM3UDocument: Equatable {
    var name: String?
    var entries: [PlaylistM3UEntry]
}

/// Extended M3U written beside the collection in Files -> ISOLATION -> Playlists.
/// Paths are written relative to that folder so the file keeps working when the whole
/// ISOLATION folder is copied to another machine.
enum PlaylistM3U {
    static let folderName = "Playlists"
    static let trackTag = "#AEON-TRACK:"
    static let fileExtensions: Set<String> = ["m3u", "m3u8"]

    static func encode(_ document: PlaylistM3UDocument) -> String {
        var lines = ["#EXTM3U"]
        if let name = document.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            lines.append("#PLAYLIST:\(singleLine(name))")
        }
        for entry in document.entries {
            let seconds = entry.duration.map { max(0, Int($0.rounded())) } ?? -1
            let display = entry.artist.isEmpty ? entry.title : "\(entry.artist) - \(entry.title)"
            lines.append("#EXTINF:\(seconds),\(singleLine(display))")
            if let trackID = entry.trackID { lines.append(trackTag + singleLine(trackID)) }
            if let path = entry.documentsRelativePath, !path.isEmpty {
                lines.append("../" + path)
            } else {
                // Tracks copied into the app's private store have no path another player
                // could open; the location still names the record so the line is not empty.
                lines.append(singleLine(display))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) -> PlaylistM3UDocument {
        var name: String?
        var entries: [PlaylistM3UEntry] = []
        var pending = PlaylistM3UEntry(trackID: nil, title: "", artist: "", duration: nil, documentsRelativePath: nil)
        var pendingHasInfo = false
        let body = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#PLAYLIST:") {
                name = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTINF:") {
                let info = String(line.dropFirst("#EXTINF:".count))
                let parts = info.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                let seconds = parts.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                pending.duration = seconds.flatMap { $0 >= 0 ? $0 : nil }
                let display = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                if let range = display.range(of: " - ") {
                    pending.artist = String(display[..<range.lowerBound])
                    pending.title = String(display[range.upperBound...])
                } else {
                    pending.artist = ""
                    pending.title = display
                }
                pendingHasInfo = true
            } else if line.hasPrefix(trackTag) {
                let id = String(line.dropFirst(trackTag.count)).trimmingCharacters(in: .whitespaces)
                pending.trackID = id.isEmpty ? nil : id
            } else if line.hasPrefix("#") {
                continue
            } else {
                pending.documentsRelativePath = documentsRelativePath(forLocation: line)
                if !pendingHasInfo {
                    let file = (line.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
                    pending.title = (file as NSString).deletingPathExtension
                }
                entries.append(pending)
                pending = PlaylistM3UEntry(trackID: nil, title: "", artist: "", duration: nil, documentsRelativePath: nil)
                pendingHasInfo = false
            }
        }
        return PlaylistM3UDocument(name: name, entries: entries)
    }

    /// Maps a location line to a path beneath Documents, or nil when it points elsewhere.
    static func documentsRelativePath(forLocation location: String) -> String? {
        var path = location.replacingOccurrences(of: "\\", with: "/")
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            path = url.path
        }
        if path.hasPrefix("/") {
            // An absolute path only helps when it points into this app's Documents.
            guard let range = path.range(of: "/Documents/") else { return nil }
            path = String(path[range.upperBound...])
        } else if path.hasPrefix("../") {
            path = String(path.dropFirst(3))
        } else if path.contains("://") {
            return nil
        } else {
            path = folderName + "/" + path
        }
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    /// A file name safe for Files: no path separators, no leading dot, bounded length.
    static func fileName(for playlistName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var cleaned = playlistName.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Playlist" }
        return String(cleaned.prefix(120)) + ".m3u8"
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }
}
