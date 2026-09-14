import SwiftUI
import UniformTypeIdentifiers

struct AeonRootView: View {
    @ObservedObject var container: AppContainer
    /// One picker at a time. Several `fileImporter` modifiers stacked on a single view
    /// leave all but one inert, which is why IMPORT FILES opened nothing on device.
    @State private var picker: ImportPickerKind?

    var body: some View {
        ZStack {
            if container.legacyBridgeRequired {
                LegacyMigrationControllerView(probe: container.legacyMigrationProbe)
                    .id(ObjectIdentifier(container.legacyMigrationProbe))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            AeonTheme.ColorToken.void.ignoresSafeArea()
            content
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Aeon native root")
                .accessibilityIdentifier("aeon.root")
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $picker) { kind in
            ImportDocumentPicker(kind: kind) { outcome in
                picker = nil
                handle(outcome, kind: kind)
            }
            .ignoresSafeArea()
        }
        .alert(
            "Import",
            isPresented: Binding(
                get: { container.libraryImportError != nil },
                set: { if !$0 { container.dismissLibraryImportError() } }
            )
        ) {
            Button("OK", role: .cancel) { container.dismissLibraryImportError() }
        } message: {
            Text(container.libraryImportError ?? "")
        }
    }

    private func handle(_ outcome: ImportPickerOutcome, kind: ImportPickerKind) {
        switch outcome {
        case .cancelled:
            return
        case .failed(let message):
            container.reportLibraryImportProblem(message)
        case .picked(let urls):
            switch kind {
            case .audioFiles:
                container.importLibrary(urls: urls, mode: .smart)
            case .folder:
                container.importLibrary(urls: urls, mode: .folder)
            case .catalogArchive:
                guard let url = urls.first else {
                    container.reportLibraryImportProblem("No catalogue file was selected.")
                    return
                }
                container.restoreCatalog(from: url)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch container.launchState {
        case .launching:
            launchMessage("OPENING AEON").padding(32)
        case .checkingLegacyLibrary:
            launchMessage("CHECKING LIBRARY").padding(32)
        case .migrationRequired(let summary):
            VStack(spacing: 14) {
                Text("LIBRARY MIGRATION")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.58))
                Text("Your library is intact.")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .foregroundStyle(.white)
                Text("\(summary.recordCount) records and \(summary.artifactCount) embedded files are ready for the native migration pipeline.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(32)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("aeon.launch.migration")
        case .migrating(let progress):
            VStack(spacing: 16) {
                Text(progress.catalogueReady ? "LIBRARY READY" : "PRESERVING LIBRARY")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.58))
                Text(progress.message)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(.white)
                ProgressView(value: progress.fraction)
                    .tint(.white)
                    .frame(maxWidth: 360)
                Text("\(progress.completedArtifacts) of \(progress.totalArtifacts) embedded files verified")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                HStack(spacing: 12) {
                    if progress.catalogueReady {
                        Button("Continue with Available Files") { container.continueAfterMigration() }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                    }
                    if let diagnosticsURL = container.migrationDiagnosticsURL {
                        ShareLink(item: diagnosticsURL) { Text("Export Diagnostics") }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                }
            }
            .padding(32)
            .accessibilityIdentifier("aeon.launch.migrating")
        case .ready:
            if let services = container.services {
                AeonReadyShell(
                    container: container,
                    services: services,
                    roots: container.roots!,
                    importProgress: container.libraryImportProgress,
                    importError: container.libraryImportError,
                    importFiles: { picker = .audioFiles },
                    importFolder: { picker = .folder }
                )
            }
        case .recovery(let issue):
            VStack(spacing: 18) {
                Text("AEON COULD NOT OPEN")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.58))
                Text(issue.message)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                if issue.catalogRecovery != nil {
                    HStack(spacing: 12) {
                        Button("Restore Catalogue") { picker = .catalogArchive }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .accessibilityIdentifier("aeon.launch.restore")
                        Button("Start Clean") { container.retryStartup() }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                            .accessibilityIdentifier("aeon.launch.retry")
                    }
                } else {
                    HStack(spacing: 12) {
                        Button("Retry") { container.retryStartup() }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                            .accessibilityIdentifier("aeon.launch.retry")
                        if let diagnosticsURL = container.migrationDiagnosticsURL {
                            ShareLink(item: diagnosticsURL) { Text("Export Diagnostics") }
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                    }
                }
            }
            .padding(32)
            .accessibilityIdentifier("aeon.launch.recovery")
        }
    }

    private func launchMessage(_ value: String) -> some View {
        VStack(spacing: 18) {
            ProgressView().tint(.white)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.62))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("aeon.launch.progress")
    }

    private func importProgress(_ progress: LibraryImportProgress) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: importFraction(progress))
                .tint(.white)
                .frame(maxWidth: 340)
            Text(importProgressLabel(progress))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.66))
            Button("Pause Import") { container.cancelLibraryImport() }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityIdentifier("aeon.library.import.cancel")
        }
        .accessibilityIdentifier("aeon.library.import.progress")
    }

    private func importFraction(_ progress: LibraryImportProgress) -> Double {
        if progress.totalGroups > 0 {
            return Double(progress.completedGroups) / Double(progress.totalGroups)
        }
        guard progress.totalFiles > 0 else { return 0 }
        return Double(progress.completedFiles) / Double(progress.totalFiles)
    }

    private func importProgressLabel(_ progress: LibraryImportProgress) -> String {
        switch progress.phase {
        case .scanning: return "SCANNING SOURCE"
        case .readingMetadata: return "READING TAGS  \(progress.completedFiles)/\(progress.totalFiles)"
        case .grouping: return "GROUPING ALBUMS"
        case .committing, .complete: return "COMMITTING ALBUMS  \(progress.completedGroups)/\(progress.totalGroups)"
        }
    }

    private func importSummary(_ result: LibraryImportResult) -> String {
        var parts = ["\(result.importedAlbums) albums", "\(result.importedTracks) tracks"]
        if !result.skippedDuplicateAlbums.isEmpty { parts.append("\(result.skippedDuplicateAlbums.count) duplicates skipped") }
        if !result.failedFiles.isEmpty { parts.append("\(result.failedFiles.count) files could not be imported") }
        return parts.joined(separator: "  ·  ")
    }
}

private struct AeonReadyShell: View {
    let container: AppContainer
    let services: AppServices
    let roots: AppStorageRoots
    let importProgress: LibraryImportProgress?
    let importError: String?
    let importFiles: () -> Void
    let importFolder: () -> Void
    @ObservedObject private var playback: PlaybackController
    @StateObject private var libraryController: LibraryController
    @StateObject private var playlistsController: PlaylistsController
    @StateObject private var settingsController: SettingsController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination = AeonDestination.sky
    @State private var portraitSidebarVisible = false
    @State private var nowPlayingVisible = false
    @State private var nowPlayingSection: NowPlayingSection?

    init(
        container: AppContainer,
        services: AppServices,
        roots: AppStorageRoots,
        importProgress: LibraryImportProgress?,
        importError: String?,
        importFiles: @escaping () -> Void,
        importFolder: @escaping () -> Void
    ) {
        self.container = container
        self.services = services
        self.roots = roots
        self.importProgress = importProgress
        self.importError = importError
        self.importFiles = importFiles
        self.importFolder = importFolder
        _playback = ObservedObject(wrappedValue: services.playbackController)
        _libraryController = StateObject(wrappedValue: LibraryController(
            repository: services.catalogRepository,
            artworkStore: services.artworkStore,
            mediaStore: services.mediaStore,
            playback: services.playbackController,
            skyRepository: services.skyRepository,
            skyController: services.skySceneController,
            metadataEnricher: services.metadataEnricher
        ))
        _playlistsController = StateObject(wrappedValue: PlaylistsController(
            repository: services.catalogRepository,
            playback: services.playbackController
        ))
        _settingsController = StateObject(wrappedValue: SettingsController(
            repository: services.catalogRepository,
            artworkStore: services.artworkStore,
            diagnostics: services.diagnosticsLog,
            playback: services.playbackController,
            archiveWriter: services.archiveWriter,
            archiveRestorer: services.archiveRestorer,
            roots: roots,
            didRestore: {
                _ = try? services.skyRepository.backfill()
                services.skySceneController.reload()
            },
            eraseAction: { [weak container] in container?.eraseEverything() ?? false }
        ))
    }

    var body: some View {
        AeonArtworkTintHost(
            playback: playback,
            catalog: services.catalogRepository,
            artworkStore: services.artworkStore
        ) {
            AeonScreen(playerVisible: playback.snapshot?.trackID != nil) { readableInsets in
                GeometryReader { geometry in
                    ZStack(alignment: .topTrailing) {
                        SkyScreen(
                            controller: services.skySceneController,
                            importProgress: importProgress,
                            importError: importError,
                            readableInsets: readableInsets,
                            showHUD: settingsController.preferences.hud,
                            highContrast: settingsController.preferences.highSkyContrast,
                            reduceMotionOverride: settingsController.preferences.reduceMotion,
                            importFiles: importFiles,
                            importFolder: importFolder
                        )
                        if destination != .sky {
                            destinationPanel(destination, geometry: geometry, insets: readableInsets)
                                .zIndex(AeonTheme.Layer.content)
                                .transition(.opacity)
                        }
                        if nowPlayingVisible {
                            nowPlayingPanel(geometry: geometry, insets: readableInsets)
                                .zIndex(AeonTheme.Layer.sheet)
                                .transition(.opacity)
                        }
                        AeonChrome(
                            destination: $destination,
                            portraitSidebarVisible: $portraitSidebarVisible,
                            playerLoaded: playback.snapshot?.trackID != nil
                        ) {
                            PlayerBar(
                                playback: playback,
                                catalog: services.catalogRepository,
                                artworkStore: services.artworkStore,
                                open: {
                                    nowPlayingSection = nil
                                    nowPlayingVisible = true
                                }
                            )
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: AeonTheme.Duration.chrome), value: destination)
        .animation(.easeOut(duration: AeonTheme.Duration.sheet), value: nowPlayingVisible)
        .onAppear { services.spectrumAnalyzer.setReduceMotion(effectiveReduceMotion) }
        .onChange(of: reduceMotion) {
            services.spectrumAnalyzer.setReduceMotion($0 || settingsController.preferences.reduceMotion || AeonTestOverrides.reduceMotion)
        }
        .onChange(of: settingsController.preferences.reduceMotion) {
            services.spectrumAnalyzer.setReduceMotion(reduceMotion || $0 || AeonTestOverrides.reduceMotion)
        }
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || settingsController.preferences.reduceMotion || AeonTestOverrides.reduceMotion
    }

    private func nowPlayingPanel(geometry: GeometryProxy, insets: AeonReadableInsets) -> some View {
        let regular = horizontalSizeClass == .regular
        let width = regular
            ? regularPanelWidth(in: geometry)
            : geometry.size.width
        return NowPlayingView(
            playback: playback,
            spectrum: services.spectrumAnalyzer,
            catalog: services.catalogRepository,
            artworkStore: services.artworkStore,
            initialSection: nowPlayingSection,
            reduceMotionOverride: settingsController.preferences.reduceMotion,
            close: { nowPlayingVisible = false },
            locate: { albumID, reduced in
                services.skySceneController.locate(id: albumID, reduceMotion: reduced)
                destination = .sky
                nowPlayingVisible = false
            }
        )
        .padding(.leading, regularContentLeadingPadding(regular: regular))
        .padding(.top, insets.top)
        .padding(.bottom, regular ? insets.bottom : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: width)
        .ignoresSafeArea(edges: .vertical)
    }

    @ViewBuilder
    private func destinationPanel(
        _ destination: AeonDestination,
        geometry: GeometryProxy,
        insets: AeonReadableInsets
    ) -> some View {
        let regular = horizontalSizeClass == .regular
        let width = regular
            ? regularPanelWidth(in: geometry)
            : geometry.size.width
        if destination == .library {
            AeonGlass {
                LibraryScreen(
                    controller: libraryController,
                    importProgress: importProgress,
                    importError: importError,
                    importFiles: importFiles,
                    importFolder: importFolder,
                    findInSky: { id, reduceMotion in
                        libraryController.findInSky(id: id, reduceMotion: reduceMotion)
                        if !regular { self.destination = .sky }
                    }
                )
                .padding(.leading, regularContentLeadingPadding(regular: regular))
                .padding(.top, insets.top)
                .padding(.bottom, regular ? insets.bottom : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width)
            .padding(.leading, regularPanelLeadingPadding(regular: regular))
            .ignoresSafeArea(edges: .vertical)
        } else if destination == .playlists {
            let bottomInset = insets.bottom + (regular && geometry.size.width <= geometry.size.height && playback.snapshot?.trackID != nil
                ? AeonTheme.Space.playerBar : 0)
            AeonGlass {
                PlaylistsScreen(controller: playlistsController, contentBottomInset: bottomInset)
                    .padding(.leading, regularContentLeadingPadding(regular: regular))
                    .padding(.top, insets.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width)
            .padding(.leading, regularPanelLeadingPadding(regular: regular))
            .ignoresSafeArea(edges: .vertical)
        } else if destination == .settings {
            let bottomInset = insets.bottom + (regular && geometry.size.width <= geometry.size.height && playback.snapshot?.trackID != nil
                ? AeonTheme.Space.playerBar : 0)
            AeonGlass {
                SettingsScreen(controller: settingsController, contentBottomInset: bottomInset) { section in
                    nowPlayingSection = section
                    nowPlayingVisible = true
                }
                .padding(.leading, regularContentLeadingPadding(regular: regular))
                .padding(.top, insets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width)
            .padding(.leading, regularPanelLeadingPadding(regular: regular))
            .ignoresSafeArea(edges: .vertical)
        } else {
            AeonGlass {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    AeonBreadcrumb(text: destination.title)
                    AeonDisplayText(destination.title.capitalized, size: 42, maximumLines: 2)
                        .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    Text("The native \(destination.rawValue) surface is connected to this persistent sky.")
                        .font(AeonTheme.FontToken.ui(.body))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    Spacer()
                }
                .padding(.leading, regularContentLeadingPadding(regular: regular))
                .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
                .padding(.top, max(AeonTheme.Space.small, insets.top))
                .padding(.bottom, max(AeonTheme.Space.edge, insets.bottom))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: width)
            .padding(.leading, regularPanelLeadingPadding(regular: regular))
            .ignoresSafeArea(edges: .vertical)
            .accessibilityIdentifier("aeon.destination.\(destination.rawValue)")
        }
    }

    private func regularPanelWidth(in geometry: GeometryProxy) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
            return geometry.size.width
        }
        return min(AeonTheme.Space.sidePanel, geometry.size.width * 0.56)
    }

    private func regularPanelLeadingPadding(regular: Bool) -> CGFloat {
        guard regular else { return 0 }
        return dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText
            ? 0
            : AeonTheme.Space.sidebar
    }

    private func regularContentLeadingPadding(regular: Bool) -> CGFloat {
        guard regular, dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText else { return 0 }
        return AeonTheme.Space.sidebar
    }
}

private struct LegacyMigrationControllerView: UIViewControllerRepresentable {
    let probe: LegacyMigrationInventoryProbe

    func makeUIViewController(context: Context) -> LegacyMigrationViewController {
        LegacyMigrationViewController(inventoryProbe: probe)
    }

    func updateUIViewController(_ controller: LegacyMigrationViewController, context: Context) {}
}
