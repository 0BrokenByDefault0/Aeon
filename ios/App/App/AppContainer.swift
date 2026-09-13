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
    let audioEngineGraph: AudioEngineGraph
    let queueScheduler: QueueScheduler
    let playbackCoordinator: PlaybackCoordinator

    static func production(
        roots: AppStorageRoots,
        fileManager: FileManager = .default
    ) throws -> AppServices {
        let aeonSupport = roots.applicationSupportURL.appendingPathComponent("Aeon", isDirectory: true)
        let stateRoot = aeonSupport.appendingPathComponent("State", isDirectory: true)
        let diagnosticsRoot = aeonSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnosticsRoot, withIntermediateDirectories: true)

        let database = try CatalogDatabase(rootURL: aeonSupport, fileManager: fileManager)
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
        let diagnostics = DiagnosticsLog(
            url: diagnosticsRoot.appendingPathComponent("audio.jsonl", isDirectory: false),
            fileManager: fileManager
        )
        let metadataProbe = MetadataProbe()
        let graph = AudioEngineGraph()
        let scheduler = QueueScheduler(graph: graph, resolver: mediaStore, probe: metadataProbe)
        let mediaInfo = NativePlaybackMediaInfoProvider(resolver: mediaStore, probe: metadataProbe)
        let coordinator = PlaybackCoordinator(
            scheduler: scheduler,
            graph: graph,
            stateStore: stateStore,
            diagnostics: diagnostics,
            mediaInfo: mediaInfo
        )
        return AppServices(
            catalogDatabase: database,
            catalogRepository: catalog,
            artworkStore: artwork,
            mediaStore: mediaStore,
            playbackStateStore: stateStore,
            diagnosticsLog: diagnostics,
            metadataProbe: metadataProbe,
            audioEngineGraph: graph,
            queueScheduler: scheduler,
            playbackCoordinator: coordinator
        )
    }
}

struct LegacyLibrarySummary: Equatable {
    let counts: [String: Int]
    let artifactCount: Int

    var recordCount: Int { counts.values.reduce(0, +) }
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
    private(set) var roots: AppStorageRoots?
    private(set) var services: AppServices?
    private(set) var migrationCoordinator: LegacyMigrationCoordinator?

    var migrationDiagnosticsURL: URL? { migrationCoordinator?.diagnosticsURL }

    private let rootsProvider: RootsProvider
    private let servicesFactory: ServicesFactory
    private let inspectLegacyLibrary: Bool
    private let cleanupURL: URL?
    private let cleanupFileManager: FileManager

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
            servicesFactory: { try AppServices.production(roots: $0, fileManager: fileManager) },
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
            launchState = .recovery(AppRecoveryState(
                code: "startup_failed",
                message: "Aeon could not open its native storage. Check available device storage, then retry."
            ))
        }
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
        services?.catalogDatabase.close()
        if let cleanupURL { try? cleanupFileManager.removeItem(at: cleanupURL) }
    }
}
