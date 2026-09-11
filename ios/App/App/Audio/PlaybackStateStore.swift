import Foundation

final class PlaybackStateStore {
    private let url: URL
    private let fileManager: FileManager

    init(baseURL: URL, fileManager: FileManager = .default) {
        url = baseURL.appendingPathComponent("transport-v1.json", isDirectory: false)
        self.fileManager = fileManager
    }

    func save(_ snapshot: PlaybackSnapshot) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    func load() -> PlaybackSnapshot? {
        guard
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
            snapshot.schemaVersion == 1
        else {
            return nil
        }
        return snapshot
    }
}
