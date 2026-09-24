import Combine
import Foundation

struct AppStorageRoots: Equatable {
    let applicationSupportURL: URL
    let documentsURL: URL
    let temporaryURL: URL

    static func production(fileManager: FileManager) throws -> AppStorageRoots {
        try AppStorageRoots(
            applicationSupportURL: fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ),
            documentsURL: fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ),
            temporaryURL: fileManager.temporaryDirectory.appendingPathComponent("Aeon", isDirectory: true),
            fileManager: fileManager
        )
    }

    static func temporary(at rootURL: URL, fileManager: FileManager) throws -> AppStorageRoots {
        try AppStorageRoots(
            applicationSupportURL: rootURL.appendingPathComponent("Application Support", isDirectory: true),
            documentsURL: rootURL.appendingPathComponent("Documents", isDirectory: true),
            temporaryURL: rootURL.appendingPathComponent("tmp", isDirectory: true),
            fileManager: fileManager
        )
    }

    private init(
        applicationSupportURL: URL,
        documentsURL: URL,
        temporaryURL: URL,
        fileManager: FileManager
    ) throws {
        self.applicationSupportURL = applicationSupportURL
        self.documentsURL = documentsURL
        self.temporaryURL = temporaryURL
        for url in [applicationSupportURL, documentsURL, temporaryURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct AppServices {
    let catalogDatabase: CatalogDatabase
    let catalogRepository: CatalogRepository
    let artworkStore: ArtworkStore
    let mediaStore: MediaStore
    let playbackStateStore: PlaybackStateStore
    let diagnosticsLog: DiagnosticsLog
    let metadataProbe: MetadataProbe
    let audioTagReader: AudioTagReader
    let artworkProcessor: ArtworkProcessor
    let metadataEnricher: MetadataEnricher
    let libraryImporter: LibraryImporter
    let importedFolderStore: ImportedFolderStore
    let archiveWriter: ArchiveWriter
    let archiveRestorer: ArchiveRestorer
    let skyRepository: SkyRepository
    let audioEngineGraph: AudioEngineGraph
    let spectrumAnalyzer: SpectrumAnalyzer
    let queueScheduler: QueueScheduler
    let playbackCoordinator: PlaybackCoordinator
    let audioSessionController: AudioSessionController
    let recoveryCoordinator: RecoveryCoordinator
    let playbackController: PlaybackController
    let remoteCommandCoordinator: RemoteCommandCoordinator
    let skySceneController: SkySceneController
    let spotlightIndexer: SpotlightIndexer

    @MainActor
    static func production(
        roots: AppStorageRoots,
        fileManager: FileManager = .default,
        startSpectrum: Bool = true,
        startPlayback: Bool = true
    ) throws -> AppServices {
        let aeonSupport = roots.applicationSupportURL.appendingPathComponent("Aeon", isDirectory: true)
        let stateRoot = aeonSupport.appendingPathComponent("State", isDirectory: true)
        let diagnosticsRoot = aeonSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnosticsRoot, withIntermediateDirectories: true)

        let database = try AppStartupFailure.perform("catalogue") {
            try CatalogDatabase(rootURL: aeonSupport, fileManager: fileManager)
        }
        let catalog = CatalogRepository(database: database)
        let artwork = try ArtworkStore(
            rootURL: aeonSupport.appendingPathComponent("Artwork", isDirectory: true),
            fileManager: fileManager
        )
        let mediaStore = try MediaStore(
            baseURL: roots.applicationSupportURL,
            documentsRoot: roots.documentsURL,
            fileManager: fileManager
        )
        let stateStore = PlaybackStateStore(baseURL: stateRoot, fileManager: fileManager)
        try seedPlaybackFixtureIfRequested(
            catalog: catalog,
            mediaStore: mediaStore,
            stateStore: stateStore
        )
        let diagnostics = DiagnosticsLog(
            url: diagnosticsRoot.appendingPathComponent("audio.jsonl", isDirectory: false),
            fileManager: fileManager
        )
        let metadataProbe = MetadataProbe()
        let tagReader = AudioTagReader(fileManager: fileManager)
        let artworkProcessor = ArtworkProcessor(store: artwork)
        let metadataEnricher = MetadataEnricher(
            repository: catalog,
            musicBrainz: MusicBrainzGenreProvider(),
            apple: AppleGenreProvider()
        )
        let libraryImporter = LibraryImporter(
            repository: catalog,
            mediaStore: mediaStore,
            tagReader: tagReader,
            artworkProcessor: artworkProcessor,
            metadataProbe: metadataProbe,
            metadataEnricher: metadataEnricher,
            fileManager: fileManager
        )
        let importedFolderStore = ImportedFolderStore(repository: catalog)
        let archiveWriter = ArchiveWriter(
            repository: catalog,
            artworkStore: artwork,
            mediaStore: mediaStore,
            temporaryRoot: roots.temporaryURL.appendingPathComponent("Archives", isDirectory: true),
            fileManager: fileManager
        )
        let archiveRestorer = ArchiveRestorer(
            repository: catalog,
            artworkStore: artwork,
            mediaStore: mediaStore,
            playbackStateStore: stateStore,
            restoreRoot: aeonSupport.appendingPathComponent("Restore", isDirectory: true),
            fileManager: fileManager
        )
        let skyRepository = SkyRepository(catalog: catalog, artworkStore: artwork)
        do {
            try skyRepository.backfill()
        } catch {
            // The sky is derived from the catalogue and is recomposed after the next import.
            // Like audio, it must not keep the Library closed; record the stage and continue.
            let failure = AppStartupFailure(stage: "sky catalogue preparation", error: error)
            try? diagnostics.record(eventCode: "startup.sky_backfill_failed.\(failure.domain).\(failure.nativeCode)")
        }
        let audioSession = AudioSessionController()
        let graph = AudioEngineGraph(activateSession: audioSession.activate)
        let spectrumAnalyzer = try AppStartupFailure.perform("spectrum setup") { try SpectrumAnalyzer(source: graph) }
        if startSpectrum {
            try AppStartupFailure.perform("spectrum registration") { try spectrumAnalyzer.start() }
        }
        graph.preferHardwareSampleRate = { [weak audioSession] rate in audioSession?.preferSampleRate(rate) }
        let scheduler = QueueScheduler(graph: graph, resolver: mediaStore, probe: metadataProbe)
        let storedPreferences = try? catalog.setting(AeonPreferences.self, forKey: SettingsController.preferencesKey)
        scheduler.setMatchesSourceSampleRate(storedPreferences?.matchSourceSampleRate ?? false)
        let mediaInfo = NativePlaybackMediaInfoProvider(resolver: mediaStore, probe: metadataProbe)
        let recovery = RecoveryCoordinator(scheduler: scheduler, graph: graph, session: audioSession)
        let coordinator = PlaybackCoordinator(
            scheduler: scheduler,
            graph: graph,
            stateStore: stateStore,
            diagnostics: diagnostics,
            mediaInfo: mediaInfo,
            recovery: recovery
        )
        audioSession.onEvent = { [weak coordinator] event in coordinator?.handleAudioSessionEvent(event) }
        let playbackAuthority: PlaybackCoordinating = startPlayback
            ? coordinator
            : PlaybackFixtureCoordinator(snapshot: stateStore.load())
        let playbackController = PlaybackController(coordinator: playbackAuthority, playlistStore: catalog)
        spectrumAnalyzer.bind(to: playbackController)
        let remoteCommands = RemoteCommandCoordinator(
            controller: playbackController,
            catalog: catalog,
            artworkStore: artwork
        )
        let skySceneController = SkySceneController(
            repository: skyRepository,
            catalog: catalog,
            playback: playbackController,
            spectrum: spectrumAnalyzer
        )
        playbackController.start()
        let spotlightIndexer = SpotlightIndexer(catalog: catalog)
        // Fixture launches never touch the device's real search index.
        if startPlayback { spotlightIndexer.setEnabled(storedPreferences?.spotlightAlbums ?? false) }
        if let marker = ProcessInfo.processInfo.arguments.firstIndex(of: "-AeonPlaybackFixture"),
           ProcessInfo.processInfo.arguments.indices.contains(marker + 1),
           ProcessInfo.processInfo.arguments[marker + 1] == "error" {
            playbackController.accept(
                failure: PlaybackFailure(
                    code: "decoder_error",
                    message: "This file could not be decoded. Choose another copy or remove it from the queue.",
                    recoverable: true,
                    trackID: "playback-fixture-track-1"
                ),
                version: 0
            )
        }
        return AppServices(
            catalogDatabase: database,
            catalogRepository: catalog,
            artworkStore: artwork,
            mediaStore: mediaStore,
            playbackStateStore: stateStore,
            diagnosticsLog: diagnostics,
            metadataProbe: metadataProbe,
            audioTagReader: tagReader,
            artworkProcessor: artworkProcessor,
            metadataEnricher: metadataEnricher,
            libraryImporter: libraryImporter,
            importedFolderStore: importedFolderStore,
            archiveWriter: archiveWriter,
            archiveRestorer: archiveRestorer,
            skyRepository: skyRepository,
            audioEngineGraph: graph,
            spectrumAnalyzer: spectrumAnalyzer,
            queueScheduler: scheduler,
            playbackCoordinator: coordinator,
            audioSessionController: audioSession,
            recoveryCoordinator: recovery,
            playbackController: playbackController,
            remoteCommandCoordinator: remoteCommands,
            skySceneController: skySceneController,
            spotlightIndexer: spotlightIndexer
        )
    }

    private static func seedPlaybackFixtureIfRequested(
        catalog: CatalogRepository,
        mediaStore: MediaStore,
        stateStore: PlaybackStateStore
    ) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "-AeonPlaybackFixture"),
              arguments.indices.contains(marker + 1),
              ["loaded", "error"].contains(arguments[marker + 1]),
              try catalog.album(id: "playback-fixture-album") == nil else { return }

        let date = Date(timeIntervalSince1970: 20_000)
        let album = CatalogAlbum(
            id: "playback-fixture-album",
            sequence: 1,
            title: "The Silver Chamber",
            artist: "Arden Vale",
            year: "2026",
            genre: "Ambient",
            artworkKey: nil,
            importedAt: date,
            updatedAt: date
        )
        let titles = ["A Signal Carried Across the Quiet", "Position of the Returning Light", "Actual Output"]
        let tracks = try titles.enumerated().map { index, title -> CatalogTrack in
            let trackID = "playback-fixture-track-\(index + 1)"
            let destination = mediaStore.mediaURL(stableID: trackID, fileExtension: "wav")
            try fixtureWAV(frequency: 110 + Double(index) * 110, duration: 8).write(to: destination, options: .atomic)
            return CatalogTrack(
                id: trackID,
                albumID: album.id,
                sequence: index + 1,
                discNumber: 1,
                trackNumber: index + 1,
                title: title,
                artist: "",
                duration: 8,
                byteCount: Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                mediaReference: .native(relativePath: destination.lastPathComponent),
                importedAt: date
            )
        }
        try catalog.insertAlbum(album, tracks: tracks)
        let queue = tracks.map { QueueItem(trackID: $0.id, albumID: $0.albumID, mediaRef: $0.mediaReference) }
        let route = RouteDescriptor(kind: .bluetooth, name: "Clay's AirPods Pro #2", sampleRate: 48000, channelCount: 2)
        try stateStore.save(PlaybackSnapshot(
            version: 0,
            trackID: tracks[0].id,
            queueRevision: 1,
            queue: queue,
            queueIndex: 0,
            position: 0,
            intent: .paused,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 0.9,
            eqEnabled: false,
            eqBands: EQView.frequencies.map { EQBand(frequency: $0, q: 1, gainDB: 0) },
            route: route,
            sourceFormat: SourceFormatDescriptor(codec: "pcm", container: "wav", sampleRate: 48000, channelCount: 1, bitDepth: 16, duration: 8),
            outputFormat: OutputFormatDescriptor(sampleRate: 48000, channelCount: 2, route: route),
            timestamp: date
        ))
    }

    private static func fixtureWAV(frequency: Double, duration: Double) -> Data {
        let sampleRate = 48_000
        let sampleCount = Int(Double(sampleRate) * duration)
        let dataByteCount = sampleCount * MemoryLayout<Int16>.size
        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(dataByteCount), to: &data)
        for frame in 0..<sampleCount {
            let envelope = min(1, Double(frame) / 800) * min(1, Double(sampleCount - frame) / 800)
            let sample = Int16(sin(2 * .pi * frequency * Double(frame) / Double(sampleRate)) * 8_000 * envelope)
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    private static func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

struct LegacyLibrarySummary: Equatable {
    let counts: [String: Int]
    let artifactCount: Int

    var recordCount: Int { counts.values.reduce(0, +) }
}

/// Keep the failing stage and native code, never file paths or raw localized errors.
struct AppStartupFailure: Error {
    let stage: String
    let domain: String
    let nativeCode: Int

    init(stage: String, error: Error) {
        self.stage = stage
        let native = error as NSError
        domain = native.domain
        nativeCode = native.code
    }

    static func perform<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch CatalogDatabaseError.recoveryRequired(let recovery) {
            throw CatalogDatabaseError.recoveryRequired(recovery)
        } catch { throw AppStartupFailure(stage: stage, error: error) }
    }

    var message: String {
        "Aeon could not finish \(stage). Your library has not been reset. Retry, or share this error code: \(domain) (\(nativeCode))."
    }
}

struct AppRecoveryState: Equatable {
    let code: String
    let message: String
    let catalogRecovery: CatalogRecovery?

    init(code: String, message: String, catalogRecovery: CatalogRecovery? = nil) {
        self.code = code
        self.message = message
        self.catalogRecovery = catalogRecovery
    }
}

enum AppLaunchState: Equatable {
    case launching
    case checkingLegacyLibrary
    case migrationRequired(LegacyLibrarySummary)
    case migrating(LegacyMigrationProgress)
    case ready
    case recovery(AppRecoveryState)

    var requiresLegacyBridge: Bool {
        switch self {
        case .checkingLegacyLibrary, .migrationRequired, .migrating: return true
        case .launching, .ready, .recovery: return false
        }
    }
}

@MainActor
final class AppContainer: ObservableObject {
    typealias RootsProvider = () throws -> AppStorageRoots
    typealias ServicesFactory = (AppStorageRoots) throws -> AppServices

    @Published private(set) var launchState: AppLaunchState = .launching
    @Published private(set) var legacyMigrationProbe = LegacyMigrationInventoryProbe()
    @Published private(set) var legacyBridgeRequired = false
    @Published private(set) var libraryImportProgress: LibraryImportProgress?
    @Published private(set) var libraryImportResult: LibraryImportResult?
    @Published private(set) var libraryImportError: String?
    private(set) var roots: AppStorageRoots?
    private(set) var services: AppServices?
    private(set) var migrationCoordinator: LegacyMigrationCoordinator?

    var migrationDiagnosticsURL: URL? { migrationCoordinator?.diagnosticsURL }

    private let rootsProvider: RootsProvider
    private let servicesFactory: ServicesFactory
    private let inspectLegacyLibrary: Bool
    private let cleanupURL: URL?
    private let cleanupFileManager: FileManager
    private var libraryImportTask: Task<Void, Never>?
    private var libraryImportCancellation: LibraryImportCancellation?
    private var libraryImportToken: UUID?
    private let processEraseToken = UUID().uuidString

    private enum LibraryImportSource: Equatable, Sendable {
        case selection
        case adoptedMusicRoot
    }

    init(
        rootsProvider: @escaping RootsProvider,
        servicesFactory: @escaping ServicesFactory,
        inspectLegacyLibrary: Bool,
        cleanupURL: URL? = nil,
        cleanupFileManager: FileManager = .default
    ) {
        self.rootsProvider = rootsProvider
        self.servicesFactory = servicesFactory
        self.inspectLegacyLibrary = inspectLegacyLibrary
        self.cleanupURL = cleanupURL
        self.cleanupFileManager = cleanupFileManager
        start()
    }

    static func production(fileManager: FileManager = .default) -> AppContainer {
        AppContainer(
            rootsProvider: { try AppStorageRoots.production(fileManager: fileManager) },
            servicesFactory: { try AppServices.production(roots: $0, fileManager: fileManager) },
            inspectLegacyLibrary: true,
            cleanupFileManager: fileManager
        )
    }

    static func inMemory(fileManager: FileManager = .default) -> AppContainer {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AeonTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AppContainer(
            rootsProvider: { try AppStorageRoots.temporary(at: root, fileManager: fileManager) },
            servicesFactory: {
                try AppServices.production(
                    roots: $0,
                    fileManager: fileManager,
                    startSpectrum: false,
                    startPlayback: false
                )
            },
            inspectLegacyLibrary: false,
            cleanupURL: root,
            cleanupFileManager: fileManager
        )
    }

    func retryStartup() {
        guard case .recovery = launchState else { return }
        start()
    }

    func continueAfterMigration() {
        guard case .migrating(let progress) = launchState, progress.catalogueReady else { return }
        launchState = .ready
    }

    /// Reports a problem that happened before an import could start. The import surfaces
    /// use the same channel as import failures so the user always sees a reason.
    func reportLibraryImportProblem(_ message: String) {
        libraryImportError = message
    }

    func dismissLibraryImportError() {
        libraryImportError = nil
    }

    func importLibrary(urls: [URL], mode: LibraryImportGroupingMode) {
        beginLibraryImport(urls: urls, mode: mode, source: .selection)
    }

    /// Catalogues audio already placed in Files -> On My iPhone -> ISOLATION -> Music.
    /// The importer adopts those files in place; it does not duplicate their bytes.
    func adoptMusicLibrary() {
        guard let resolvedServices = services else {
            libraryImportError = "Aeon is still opening your library. Try the scan again in a moment."
            return
        }
        beginLibraryImport(
            urls: [resolvedServices.mediaStore.documentsMusicRoot],
            mode: .folder,
            source: .adoptedMusicRoot
        )
    }

    private func beginLibraryImport(
        urls: [URL],
        mode: LibraryImportGroupingMode,
        source: LibraryImportSource
    ) {
        guard libraryImportTask == nil else {
            libraryImportError = "An import is already running. Wait for it to finish, or pause it, then try again."
            return
        }
        guard case .ready = launchState, let resolvedServices = services else {
            libraryImportError = "Aeon is still opening your library. Try the import again in a moment."
            return
        }
        guard !urls.isEmpty else {
            libraryImportError = "Nothing was selected. Choose audio files to import."
            return
        }
        let importer = resolvedServices.libraryImporter

        // Only externally selected folders need bookmarks. Aeon's own Files-visible
        // Music directory is already inside the app's persistent Documents container.
        if source == .selection, mode == .folder {
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    try resolvedServices.importedFolderStore.remember(url)
                } catch {
                    try? resolvedServices.diagnosticsLog.record(
                        eventCode: "library.import.bookmark_failed",
                        filePath: url.lastPathComponent
                    )
                }
            }
        }

        let cancellation = LibraryImportCancellation()
        let effectiveMode: LibraryImportGroupingMode
        if mode == .smart,
           (try? resolvedServices.catalogRepository.setting(Bool.self, forKey: SettingsController.importGroupingKey)) ?? true {
            effectiveMode = .single
        } else {
            effectiveMode = mode
        }
        let importToken = UUID()
        let skyRepository = resolvedServices.skyRepository
        let diagnostics = resolvedServices.diagnosticsLog
        libraryImportToken = importToken
        libraryImportCancellation = cancellation
        libraryImportProgress = LibraryImportProgress(
            phase: .scanning,
            completedFiles: 0,
            totalFiles: 0,
            completedGroups: 0,
            totalGroups: 0
        )
        libraryImportResult = nil
        libraryImportError = nil
        if source == .adoptedMusicRoot {
            try? resolvedServices.diagnosticsLog.record(eventCode: "library.adopt.started")
        }
        libraryImportTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { () async throws -> LibraryImportResult in
                    let result: LibraryImportResult
                    if source == .adoptedMusicRoot {
                        result = try await importer.adoptMusicLibrary(cancellation: cancellation) { progress in
                            Task { @MainActor [weak self] in self?.acceptLibraryImportProgress(progress, token: importToken) }
                        }
                    } else {
                        result = try await importer.importURLs(
                            urls,
                            mode: effectiveMode,
                            cancellation: cancellation
                        ) { progress in
                            Task { @MainActor [weak self] in self?.acceptLibraryImportProgress(progress, token: importToken) }
                        }
                    }
                    // Charting decodes artwork for every album, so it stays off the main thread.
                    // The albums are already committed: a sky failure is logged rather than
                    // reported as a failed import, and the next backfill charts them.
                    do {
                        try skyRepository.backfill()
                    } catch {
                        try? diagnostics.record(eventCode: "library.import.sky_backfill_failed")
                    }
                    return result
                }.value
                self?.services?.skySceneController.reload()
                self?.libraryImportResult = result
                if source == .adoptedMusicRoot {
                    try? self?.services?.diagnosticsLog.record(eventCode: "library.adopt.completed")
                }
            } catch LibraryImportError.cancelled {
                self?.libraryImportError = source == .adoptedMusicRoot
                    ? "Library scan paused. Run Adopt Library again to resume."
                    : "Import paused. Select the same files or folder to resume."
            } catch LibraryImportError.noSupportedAudio {
                self?.libraryImportError = source == .adoptedMusicRoot
                    ? "No supported audio was found in Files → On My iPhone → ISOLATION → Music. Copy album folders there, then run Adopt Library again."
                    : "No supported audio files were found. Aeon reads \(AudioTagReader.supportedExtensions.sorted().joined(separator: ", "))."
            } catch LibraryImportError.accessDenied {
                self?.libraryImportError = source == .adoptedMusicRoot
                    ? "Aeon could not read its Music folder. Reopen the app and try Adopt Library again."
                    : "Aeon could not open that location. Choose files on this iPhone or in iCloud Drive, and make sure the location is still available."
            } catch LibraryImportError.sourceUnavailable {
                self?.libraryImportError = "Those files have not finished downloading from iCloud. Open them once in the Files app, then import again."
            } catch {
                self?.libraryImportError = source == .adoptedMusicRoot
                    ? "The library scan stopped before the next album could be catalogued. Your music files were not changed."
                    : "Import stopped before the next album could be committed. Select the same source to resume."
            }
            self?.libraryImportToken = nil
            self?.libraryImportProgress = nil
            self?.libraryImportCancellation = nil
            self?.libraryImportTask = nil
        }
    }

    /// Progress hops to the main actor in separate tasks, so one can arrive after its
    /// import has finished. Only the running import may move the progress bar.
    private func acceptLibraryImportProgress(_ progress: LibraryImportProgress, token: UUID) {
        guard libraryImportToken == token else { return }
        libraryImportProgress = progress
    }

    func cancelLibraryImport() {
        libraryImportCancellation?.cancel()
    }

    func applicationDidEnterForeground() {
        services?.playbackController.applicationDidEnterForeground()
    }

    func applicationDidEnterBackground() {
        services?.playbackController.applicationDidEnterBackground()
    }

    @discardableResult
    func eraseEverything() -> Bool {
        guard let roots, let currentServices = services else { return false }
        currentServices.playbackController.pause()
        // The replacement services start their own analyser; stop the old one's timer.
        currentServices.spectrumAnalyzer.stop()
        // Nothing erased should stay findable from system search.
        currentServices.spotlightIndexer.setEnabled(false)
        currentServices.catalogDatabase.close()
        launchState = .launching
        services = nil

        let supportRoot = roots.applicationSupportURL.appendingPathComponent("Aeon", isDirectory: true)
        let quarantineBase = supportRoot.appendingPathComponent("EraseQuarantine", isDirectory: true)
        let quarantine = quarantineBase.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let marker = quarantineBase.appendingPathComponent("pending.json", isDirectory: false)
        let targets: [(source: URL, name: String)] = [
            (supportRoot.appendingPathComponent("Catalog", isDirectory: true), "support-Catalog"),
            (supportRoot.appendingPathComponent("Artwork", isDirectory: true), "support-Artwork"),
            (supportRoot.appendingPathComponent("Media", isDirectory: true), "support-Media"),
            (supportRoot.appendingPathComponent("State", isDirectory: true), "support-State"),
            (roots.documentsURL.appendingPathComponent("Music/_Imported", isDirectory: true), "documents-Imported"),
            (roots.documentsURL.appendingPathComponent("Music/_Migrated", isDirectory: true), "documents-Migrated"),
            (roots.documentsURL.appendingPathComponent("Music/_Restored", isDirectory: true), "documents-Restored")
        ]
        var moved: [(source: URL, destination: URL)] = []
        do {
            try cleanupFileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
            for target in targets where cleanupFileManager.fileExists(atPath: target.source.path) {
                let destination = quarantine.appendingPathComponent(target.name, isDirectory: true)
                try cleanupFileManager.moveItem(at: target.source, to: destination)
                moved.append((target.source, destination))
            }
            let markerData = try JSONSerialization.data(withJSONObject: ["token": processEraseToken], options: [.sortedKeys])
            try markerData.write(to: marker, options: .atomic)
            services = try servicesFactory(roots)
            launchState = .ready
            return true
        } catch {
            services?.catalogDatabase.close()
            services = nil
            for value in moved.reversed() where cleanupFileManager.fileExists(atPath: value.destination.path) {
                try? cleanupFileManager.createDirectory(at: value.source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? cleanupFileManager.moveItem(at: value.destination, to: value.source)
            }
            try? cleanupFileManager.removeItem(at: quarantineBase)
            services = try? servicesFactory(roots)
            launchState = services == nil
                ? .recovery(AppRecoveryState(code: "erase_failed", message: "Aeon could not create a fresh catalogue. The quarantined library was restored."))
                : .ready
            return false
        }
    }

    func restoreCatalog(from sourceURL: URL) {
        guard case .recovery(let issue) = launchState,
              let recovery = issue.catalogRecovery else { return }
        launchState = .launching
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let temporary = recovery.originalDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent(".restore-\(UUID().uuidString).sqlite3", isDirectory: false)
        do {
            try? cleanupFileManager.removeItem(at: temporary)
            try cleanupFileManager.copyItem(at: sourceURL, to: temporary)
            let validation = try CatalogDatabase(
                url: temporary,
                recoveryDirectory: recovery.quarantineDirectory,
                fileManager: cleanupFileManager
            )
            try validation.checkpoint()
            validation.close()
            try? cleanupFileManager.removeItem(atPath: temporary.path + "-wal")
            try? cleanupFileManager.removeItem(atPath: temporary.path + "-shm")
            guard !cleanupFileManager.fileExists(atPath: recovery.originalDatabaseURL.path) else {
                throw CatalogDatabaseError.invalidResult("restore_destination_exists")
            }
            try cleanupFileManager.moveItem(at: temporary, to: recovery.originalDatabaseURL)
            start()
        } catch {
            try? cleanupFileManager.removeItem(at: temporary)
            try? cleanupFileManager.removeItem(atPath: temporary.path + "-wal")
            try? cleanupFileManager.removeItem(atPath: temporary.path + "-shm")
            launchState = .recovery(AppRecoveryState(
                code: "catalog_restore_failed",
                message: "That catalogue could not be verified. Choose another catalogue file or start with a clean one.",
                catalogRecovery: recovery
            ))
        }
    }

    private func start() {
        launchState = .launching
        do {
            if services == nil {
                let resolvedRoots = try rootsProvider()
                roots = resolvedRoots
                let resolvedServices = try servicesFactory(resolvedRoots)
                services = resolvedServices
                completePendingEraseIfNeeded(roots: resolvedRoots)
            }
            if inspectLegacyLibrary { beginLegacyInspection() }
            else { launchState = .ready }
        } catch CatalogDatabaseError.recoveryRequired(let recovery) {
            services = nil
            launchState = .recovery(AppRecoveryState(
                code: "catalog_quarantined",
                message: "The damaged catalogue was isolated without touching music, artwork, or the legacy library. Restore a known-good catalogue or start clean.",
                catalogRecovery: recovery
            ))
        } catch {
            services = nil
            let failure = (error as? AppStartupFailure) ?? AppStartupFailure(stage: "file storage setup", error: error)
            launchState = .recovery(AppRecoveryState(
                code: "startup_failed",
                message: failure.message
            ))
        }
    }

    private func completePendingEraseIfNeeded(roots: AppStorageRoots) {
        let quarantine = roots.applicationSupportURL.appendingPathComponent("Aeon/EraseQuarantine", isDirectory: true)
        let marker = quarantine.appendingPathComponent("pending.json", isDirectory: false)
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              object["token"] != processEraseToken else { return }
        try? cleanupFileManager.removeItem(at: quarantine)
    }

    private func beginLegacyInspection() {
        let probe = LegacyMigrationInventoryProbe()
        probe.onCompletion = { [weak self] result in
            self?.acceptLegacyInventory(result)
        }
        legacyMigrationProbe = probe
        legacyBridgeRequired = true
        launchState = .checkingLegacyLibrary
    }

    private func acceptLegacyInventory(
        _ result: Result<LegacyMigrationInventorySnapshot, LegacyMigrationFailure>
    ) {
        switch result {
        case .success(let snapshot):
            let summary = LegacyLibrarySummary(
                counts: snapshot.inventory.counts,
                artifactCount: snapshot.blobs.count
            )
            guard summary.recordCount > 0 else {
                legacyBridgeRequired = false
                launchState = .ready
                return
            }
            launchState = .migrationRequired(summary)
            guard let services else {
                launchState = .recovery(AppRecoveryState(code: "migration_services_unavailable", message: "Native storage is unavailable."))
                return
            }
            let coordinator = LegacyMigrationCoordinator(
                repository: services.catalogRepository,
                artworkStore: services.artworkStore,
                mediaStore: services.mediaStore,
                metadataProbe: services.metadataProbe
            )
            coordinator.onProgress = { [weak self] progress in
                guard let self else { return }
                if progress.phase == .failed {
                    self.launchState = .recovery(AppRecoveryState(code: "legacy_migration_failed", message: progress.message))
                } else {
                    if case .ready = self.launchState, progress.catalogueReady {
                        // Continue keeps the native library visible while the hidden bridge finishes audio.
                    } else {
                        self.launchState = .migrating(progress)
                    }
                    if progress.sourceComplete { self.legacyBridgeRequired = false }
                }
                if progress.catalogueReady {
                    _ = try? services.skyRepository.backfill()
                }
            }
            migrationCoordinator = coordinator
            legacyMigrationProbe.artifactReceiver = coordinator
            do {
                try coordinator.prepare(snapshot: snapshot)
            } catch {
                coordinator.receive(failure: LegacyMigrationFailure(
                    code: "legacy_migration_failed",
                    message: "The native migration could not validate the legacy catalogue."
                ))
                launchState = .recovery(AppRecoveryState(
                    code: "legacy_migration_failed",
                    message: "The legacy library stayed untouched, but its native copy could not be prepared. Retry or export diagnostics."
                ))
            }
        case .failure(let failure):
            if failure.message.localizedCaseInsensitiveContains("not found") {
                legacyBridgeRequired = false
                launchState = .ready
            } else {
                launchState = .recovery(AppRecoveryState(code: failure.code, message: failure.message))
            }
        }
    }

    deinit {
        libraryImportCancellation?.cancel()
        services?.catalogDatabase.close()
        if let cleanupURL { try? cleanupFileManager.removeItem(at: cleanupURL) }
    }
}
