import Combine
import Foundation
import ImageIO

enum SettingsSleepTimer: String, CaseIterable, Codable, Identifiable {
    case off
    case minutes15
    case minutes30
    case minutes60
    case endOfAlbum

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "OFF"
        case .minutes15: return "15 MIN"
        case .minutes30: return "30 MIN"
        case .minutes60: return "1 HOUR"
        case .endOfAlbum: return "END OF ALBUM"
        }
    }
}

struct AeonPreferences: Codable, Equatable {
    var oneImportOneAlbum = true
    var metadataLookups = false
    var hud = false
    var highSkyContrast = false
    var reduceMotion = false
    var matchSourceSampleRate = false
    var spotlightAlbums = false

    init() {}

    /// Stored preferences predate later keys; a missing key keeps its default instead of
    /// discarding every other choice the collector made.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AeonPreferences()
        oneImportOneAlbum = try container.decodeIfPresent(Bool.self, forKey: .oneImportOneAlbum) ?? defaults.oneImportOneAlbum
        metadataLookups = try container.decodeIfPresent(Bool.self, forKey: .metadataLookups) ?? defaults.metadataLookups
        hud = try container.decodeIfPresent(Bool.self, forKey: .hud) ?? defaults.hud
        highSkyContrast = try container.decodeIfPresent(Bool.self, forKey: .highSkyContrast) ?? defaults.highSkyContrast
        reduceMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? defaults.reduceMotion
        matchSourceSampleRate = try container.decodeIfPresent(Bool.self, forKey: .matchSourceSampleRate) ?? defaults.matchSourceSampleRate
        spotlightAlbums = try container.decodeIfPresent(Bool.self, forKey: .spotlightAlbums) ?? defaults.spotlightAlbums
    }
}

struct AeonStorageMeasurement: Equatable {
    var libraryBytes: Int64 = 0
    var artworkBytes: Int64 = 0
    var catalogueBytes: Int64 = 0
    var availableBytes: Int64 = 0

    var usedBytes: Int64 { libraryBytes + artworkBytes + catalogueBytes }
    var fraction: Double {
        let total = usedBytes + availableBytes
        return total > 0 ? Double(usedBytes) / Double(total) : 0
    }
}

enum SettingsExportKind: Equatable {
    case catalog
    case fullBackup
    case activity
    case diagnostics
}

@MainActor
final class SettingsController: ObservableObject {
    static let preferencesKey = "app.settings.v1"
    static let importGroupingKey = "library.import.one_album"
    private static let artworkRepairCursorKey = "artwork.repair.cursor"

    @Published private(set) var preferences: AeonPreferences
    @Published private(set) var sleepTimer: SettingsSleepTimer = .off
    /// Mirrors the coordinator so the Settings control has something to bind to. The
    /// whole ReplayGain pipeline shipped without any way to reach it from the app.
    @Published private(set) var replayGainMode: ReplayGainMode = .off
    @Published private(set) var sleepStatus = ""
    @Published private(set) var storage = AeonStorageMeasurement()
    @Published private(set) var operationMessage: String?
    @Published private(set) var operationProgress: Double?
    @Published private(set) var exportURL: URL?
    @Published private(set) var exportKind: SettingsExportKind?
    @Published private(set) var isRestoring = false
    @Published private(set) var eraseFailed = false

    let playback: PlaybackController
    private let repository: CatalogRepository
    private let artworkStore: ArtworkStore
    private let diagnostics: DiagnosticsLog
    private let archiveWriter: ArchiveWriter
    private let archiveRestorer: ArchiveRestorer
    private let roots: AppStorageRoots
    private let fileManager: FileManager
    private let didRestore: () -> Void
    private let eraseAction: () -> Bool
    private let setSampleRateMatching: (Bool) -> Void
    private let setSpotlightIndexing: (Bool) -> Void
    private var sleepTask: Task<Void, Never>?
    private var playbackObservation: AnyCancellable?
    private var sleepAlbumID: String?

    init(
        repository: CatalogRepository,
        artworkStore: ArtworkStore,
        diagnostics: DiagnosticsLog,
        playback: PlaybackController,
        archiveWriter: ArchiveWriter,
        archiveRestorer: ArchiveRestorer,
        roots: AppStorageRoots,
        fileManager: FileManager = .default,
        didRestore: @escaping () -> Void,
        eraseAction: @escaping () -> Bool,
        setSampleRateMatching: @escaping (Bool) -> Void = { _ in },
        setSpotlightIndexing: @escaping (Bool) -> Void = { _ in }
    ) {
        self.setSampleRateMatching = setSampleRateMatching
        self.setSpotlightIndexing = setSpotlightIndexing
        self.repository = repository
        self.artworkStore = artworkStore
        self.diagnostics = diagnostics
        self.playback = playback
        self.archiveWriter = archiveWriter
        self.archiveRestorer = archiveRestorer
        self.roots = roots
        self.fileManager = fileManager
        self.didRestore = didRestore
        self.eraseAction = eraseAction
        preferences = (try? repository.setting(AeonPreferences.self, forKey: Self.preferencesKey)) ?? AeonPreferences()
        if let legacyEnabled = try? repository.setting(Bool.self, forKey: MetadataEnricher.lookupEnabledKey) {
            preferences.metadataLookups = legacyEnabled
        }
        replayGainMode = playback.snapshot?.replayGainMode ?? .off
        playbackObservation = playback.$snapshot.sink { [weak self] snapshot in
            self?.observeSleepAlbum(snapshot)
            if let mode = snapshot?.replayGainMode { self?.replayGainMode = mode }
        }
        measureStorage()
    }

    deinit { sleepTask?.cancel() }

    func setOneImportOneAlbum(_ enabled: Bool) {
        preferences.oneImportOneAlbum = enabled
        persistPreferences()
        try? repository.setSetting(enabled, forKey: Self.importGroupingKey)
    }

    func setReplayGainMode(_ mode: ReplayGainMode) {
        replayGainMode = mode
        playback.setReplayGainMode(mode)
    }

    func setMetadataLookups(_ enabled: Bool) {
        preferences.metadataLookups = enabled
        persistPreferences()
        try? repository.setSetting(enabled, forKey: MetadataEnricher.lookupEnabledKey)
    }

    func setMatchSourceSampleRate(_ enabled: Bool) {
        preferences.matchSourceSampleRate = enabled
        persistPreferences()
        setSampleRateMatching(enabled)
    }

    func setSpotlightAlbums(_ enabled: Bool) {
        preferences.spotlightAlbums = enabled
        persistPreferences()
        setSpotlightIndexing(enabled)
    }

    func setHUD(_ enabled: Bool) {
        preferences.hud = enabled
        persistPreferences()
    }

    func setHighSkyContrast(_ enabled: Bool) {
        preferences.highSkyContrast = enabled
        persistPreferences()
    }

    func setReduceMotion(_ enabled: Bool) {
        preferences.reduceMotion = enabled
        persistPreferences()
    }

    func resetEQ() {
        let bands = EQView.frequencies.map { EQBand(frequency: $0, q: 1, gainDB: 0) }
        playback.setEQ(enabled: false, bands: bands)
        operationMessage = "Equalizer default reset to flat and bypassed."
    }

    func resetSpectrum() {
        playback.setSpectrumMode(.ambient)
        operationMessage = "Spectrum default reset to ambient."
    }

    func setSleepTimer(_ value: SettingsSleepTimer) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAlbumID = nil
        sleepTimer = value
        switch value {
        case .off:
            sleepStatus = ""
        case .endOfAlbum:
            sleepAlbumID = playback.snapshot?.trackID.flatMap { try? repository.track(id: $0)?.albumID }
            sleepStatus = "Sleeping when this album ends."
        case .minutes15, .minutes30, .minutes60:
            let minutes = value == .minutes15 ? 15 : value == .minutes30 ? 30 : 60
            let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sleepStatus = "Sleeping at \(date.formatted(date: .omitted, time: .shortened))."
            sleepTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.fadeToSleep()
            }
        }
    }

    func measureStorage() {
        let roots = roots
        Task { [weak self, fileManager] in
            let measurement = await Task.detached(priority: .utility) {
                let library = Self.directoryBytes(roots.documentsURL.appendingPathComponent("Music", isDirectory: true), fileManager: fileManager)
                let artwork = Self.directoryBytes(roots.applicationSupportURL.appendingPathComponent("Aeon/Artwork", isDirectory: true), fileManager: fileManager)
                let catalogue = Self.directoryBytes(roots.applicationSupportURL.appendingPathComponent("Aeon/Catalog", isDirectory: true), fileManager: fileManager)
                let available = (try? roots.documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
                return AeonStorageMeasurement(
                    libraryBytes: library,
                    artworkBytes: artwork,
                    catalogueBytes: catalogue,
                    availableBytes: Int64(available)
                )
            }.value
            self?.storage = measurement
        }
    }

    func repairArtwork() {
        guard operationProgress == nil else { return }
        operationProgress = 0
        operationMessage = "Checking artwork…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let total = try repository.albumCount()
                var offset = (try repository.setting(Int.self, forKey: Self.artworkRepairCursorKey)) ?? 0
                var repaired = 0
                while offset < total {
                    let page = try repository.albumPage(offset: offset, limit: CatalogDatabase.maximumPageSize, sort: .recentlyAdded)
                    for summary in page {
                        if let key = summary.artworkKey {
                            let valid = (try? artworkStore.url(forKey: key)).flatMap {
                                CGImageSourceCreateWithURL($0 as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                            }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
                            if !valid, var album = try repository.album(id: summary.id) {
                                album.artworkKey = nil
                                album.updatedAt = Date()
                                try repository.updateAlbum(album)
                                try? artworkStore.remove(key: key)
                                repaired += 1
                            }
                        }
                        offset += 1
                        try repository.setSetting(offset, forKey: Self.artworkRepairCursorKey)
                        operationProgress = total == 0 ? 1 : Double(offset) / Double(total)
                        await Task.yield()
                    }
                    if page.isEmpty { break }
                }
                try repository.removeSetting(forKey: Self.artworkRepairCursorKey)
                operationMessage = repaired == 0 ? "Every stored cover reads cleanly." : "\(repaired) unreadable cover\(repaired == 1 ? "" : "s") cleared."
            } catch {
                operationMessage = "Artwork repair paused. Run it again to resume."
            }
            operationProgress = nil
            measureStorage()
        }
    }

    func exportCatalogue() { prepareExport(kind: .catalog) }
    func exportFullBackup() { prepareExport(kind: .fullBackup) }
    func exportActivity() { prepareExport(kind: .activity) }
    func exportDiagnostics() { prepareExport(kind: .diagnostics) }

    func restore(from url: URL) {
        guard !isRestoring else { return }
        isRestoring = true
        operationProgress = 0
        operationMessage = "Validating every record and checksum…"
        let accessed = url.startAccessingSecurityScopedResource()
        let archiveRestorer = archiveRestorer
        Task { [weak self] in
            guard let self else { return }
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try archiveRestorer.restore(from: url) { progress in
                        Task { @MainActor [weak self] in
                            self?.operationMessage = "Restoring \(progress.currentPath)…"
                        }
                    }
                }.value
                didRestore()
                operationMessage = "Restore complete — \(result.albumCount) albums and \(result.playlistCount) playlists validated."
            } catch {
                operationMessage = "Backup rejected before the catalogue changed."
            }
            operationProgress = nil
            isRestoring = false
            measureStorage()
        }
    }

    @discardableResult
    func eraseEverything(confirmation: String) -> Bool {
        guard confirmation == "ERASE" else {
            eraseFailed = true
            return false
        }
        let erased = eraseAction()
        eraseFailed = !erased
        if erased {
            preferences = AeonPreferences()
            operationMessage = "The sky is dark again."
        }
        return erased
    }

    func clearExport() {
        if let exportURL { try? fileManager.removeItem(at: exportURL) }
        exportURL = nil
        exportKind = nil
    }

    func clearMessage() { operationMessage = nil }

    private func prepareExport(kind: SettingsExportKind) {
        guard exportURL == nil, operationProgress == nil else { return }
        operationProgress = 0
        operationMessage = kind == .fullBackup ? "Packing the sky…" : "Preparing export…"
        let directory = roots.temporaryURL.appendingPathComponent("Exports", isDirectory: true)
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let name: String
        switch kind {
        case .catalog: name = "isolation-catalog-\(date).json"
        case .fullBackup: name = "isolation-backup-\(date).zip"
        case .activity: name = "aeon-activity-\(date).json"
        case .diagnostics: name = "aeon-diagnostics-\(date).json"
        }
        let output = directory.appendingPathComponent(name, isDirectory: false)
        let archiveWriter = archiveWriter
        let playbackSnapshot = playback.snapshot
        let diagnosticEntries = kind == .diagnostics ? diagnostics.entries() : []
        let fileManager = fileManager
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? fileManager.removeItem(at: output)
                    switch kind {
                    case .catalog:
                        try archiveWriter.writeCatalogue(to: output, playbackSnapshot: playbackSnapshot)
                    case .fullBackup:
                        try archiveWriter.writeFullBackup(to: output, playbackSnapshot: playbackSnapshot) { progress in
                            Task { @MainActor [weak self] in
                                self?.operationMessage = "Packing \(progress.currentPath)…"
                            }
                        }
                    case .activity:
                        try archiveWriter.writeActivityLog(to: output)
                    case .diagnostics:
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(diagnosticEntries).write(to: output, options: .atomic)
                    }
                }.value
                exportURL = output
                exportKind = kind
                operationMessage = "Choose where to keep it."
            } catch {
                try? fileManager.removeItem(at: output)
                operationMessage = "The export could not be completed. Check that every managed audio file is available."
            }
            operationProgress = nil
        }
    }

    private func persistPreferences() {
        try? repository.setSetting(preferences, forKey: Self.preferencesKey)
    }

    private func observeSleepAlbum(_ snapshot: PlaybackSnapshot?) {
        guard sleepTimer == .endOfAlbum, let expected = sleepAlbumID,
              let trackID = snapshot?.trackID,
              let current = try? repository.track(id: trackID)?.albumID,
              current != expected else { return }
        Task { [weak self] in await self?.fadeToSleep() }
    }

    /// Amplitude at `progress` (0 = start of the fade, 1 = silence) on a decibel-linear
    /// taper down to -60 dB.
    ///
    /// A straight amplitude ramp sounds wrong: loudness tracks roughly the logarithm of
    /// amplitude, so halving amplitude is only about a 6 dB drop. The old 20-step linear
    /// fade therefore seemed to hold at volume and then fall off a cliff at the very end.
    /// This taper sounds like a steady decline instead.
    nonisolated static func sleepFadeAmplitude(progress: Double) -> Double {
        let clamped = min(1, max(0, progress))
        guard clamped < 1 else { return 0 }
        return pow(10, (-60 * clamped) / 20)
    }

    private static let sleepFadeSeconds = 8.0
    private static let sleepFadeSteps = 160

    private func fadeToSleep() async {
        let original = playback.snapshot?.masterVolume ?? 0.9
        let steps = Self.sleepFadeSteps
        // 20 Hz stepping on an un-smoothed mixer parameter zippered on sustained tones;
        // 160 steps over 8 s is 20 ms apart and inaudible as steps.
        let interval = UInt64((Self.sleepFadeSeconds / Double(steps)) * 1_000_000_000)
        for step in 0...steps {
            guard !Task.isCancelled else { return }
            playback.setVolume(Float(original * Self.sleepFadeAmplitude(progress: Double(step) / Double(steps))))
            try? await Task.sleep(nanoseconds: interval)
        }
        playback.pause()
        playback.setVolume(Float(original))
        sleepTask = nil
        sleepAlbumID = nil
        sleepTimer = .off
        sleepStatus = "Goodnight — the sky keeps watch."
    }

    nonisolated private static func directoryBytes(_ root: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
