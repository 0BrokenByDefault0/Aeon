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

        let mediaStore = try MediaStore(baseURL: roots.applicationSupportURL, fileManager: fileManager)
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
}

enum AppLaunchState: Equatable {
    case launching
    case checkingLegacyLibrary
    case migrationRequired(LegacyLibrarySummary)
    case ready
    case recovery(AppRecoveryState)

    var requiresLegacyBridge: Bool {
        switch self {
        case .checkingLegacyLibrary, .migrationRequired: return true
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
    private(set) var roots: AppStorageRoots?
    private(set) var services: AppServices?

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

    private func start() {
        launchState = .launching
        do {
            if services == nil {
                let resolvedRoots = try rootsProvider()
                let resolvedServices = try servicesFactory(resolvedRoots)
                roots = resolvedRoots
                services = resolvedServices
            }
            if inspectLegacyLibrary { beginLegacyInspection() }
            else { launchState = .ready }
        } catch {
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
            launchState = summary.recordCount == 0 ? .ready : .migrationRequired(summary)
        case .failure(let failure):
            if failure.message.localizedCaseInsensitiveContains("not found") {
                launchState = .ready
            } else {
                launchState = .recovery(AppRecoveryState(code: failure.code, message: failure.message))
            }
        }
    }

    deinit {
        if let cleanupURL { try? cleanupFileManager.removeItem(at: cleanupURL) }
    }
}
