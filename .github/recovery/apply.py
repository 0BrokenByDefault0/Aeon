#!/usr/bin/env python3
"""Prepare a pinned, reversible recovery preview without touching the audio engine."""
from pathlib import Path
import hashlib
import json
import subprocess
import textwrap

MANIFEST = Path('.github/recovery/applied.json')
PIN = 'fd0b5a91aae781373c0043300429cf3e73aab5e2'
BASE = {
    'ios/App/App/Import/ImportPicker.swift': '669fdf62a23d39cef1c99ca030a59f75e1353dd8',
    'ios/App/App/DesignSystem/AeonTheme.swift': '9ece9814f614ee7d0897b4d2bd7b7966b78a3d63',
    'ios/App/App/DesignSystem/AeonChrome.swift': '91d158900fdf2a27983e507b4b1932042bbd7cdc',
    'ios/App/App/DesignSystem/AeonComponents.swift': 'd730d608de949986bf82fdd1a329421a176c49ed',
    'ios/App/App/Features/Root/AeonRootView.swift': '2aadd4a2a195e965272cd21fdfc6a885bebbad70',
    'ios/App/App/Features/Library/LibraryScreen.swift': None,
    'ios/App/App/Features/Sky/SkyScreen.swift': '396efa132505dc8aec4db6e9a84931e050a99de2',
    'ios/App/App/Features/Playlists/PlaylistsScreen.swift': 'd8a9c1433b601a065cb6879a9a390ccd39decffe',
    'ios/App/App/Features/Settings/SettingsScreen.swift': '15c66c12a1c316419614c078aad68a265907bbf4',
    'ios/App/App/AppContainer.swift': '376cb46ee54390087358576ad937dcc663aa697f',
    'ios/App/App/AeonApp.swift': 'c3ad423a49cb5116162991168960675691500048',
    'ios/App/AppUITests/ImportPickerPresentationTests.swift': '023d17b41ecb6cf747e5b028c740e862b9f9d512',
}


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


if MANIFEST.exists():
    manifest = json.loads(MANIFEST.read_text())
    for path, sha in manifest['sha256'].items():
        assert digest(path) == sha, f'Previously prepared source changed: {path}'
    print('Recovery source already prepared and verified.')
    raise SystemExit(0)

for path, expected in BASE.items():
    expected = expected or git('rev-parse', f'{PIN}:{path}')
    assert git('hash-object', path) == expected, f'Baseline changed: {path}'

sources = {p: Path(p).read_text() for p in BASE}


def replace(path, before, after, count=1):
    assert sources[path].count(before) == count, f'{path}: expected {count} matches: {before[:90]!r}'
    sources[path] = sources[path].replace(before, after)


def block(path, start, end, replacement):
    source = sources[path]
    assert source.count(start) == 1, f'{path}: ambiguous start {start}'
    a = source.index(start)
    b = source.index(end, a + len(start))
    sources[path] = source[:a] + replacement + source[b:]


picker = 'ios/App/App/Import/ImportPicker.swift'
replace(picker, '        controller.shouldShowFileExtensions = true',
        '        controller.shouldShowFileExtensions = true\n        controller.view.accessibilityIdentifier = "aeon.import.document-picker"')
sources[picker] += r'''

/// Retain security-scoped access from the picker callback through asynchronous import.
/// A false return is not automatically an error: app-container URLs need no grant.
final class ImportAccessLease: @unchecked Sendable {
    private let accessed: [URL]
    init(urls: [URL]) {
        accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
}

struct PendingImportSelection {
    let kind: ImportPickerKind
    let outcome: ImportPickerOutcome
    let accessLease: ImportAccessLease

    init(kind: ImportPickerKind, outcome: ImportPickerOutcome) {
        self.kind = kind
        self.outcome = outcome
        if case .picked(let urls) = outcome {
            accessLease = ImportAccessLease(urls: urls)
        } else {
            accessLease = ImportAccessLease(urls: [])
        }
    }
}

/// Direct actions. There is no source-choice sheet to dismiss before opening Files.
struct AeonImportActions: View {
    let selectFiles: () -> Void
    let selectFolder: () -> Void
    var disabled = false

    var body: some View {
        VStack(spacing: 0) {
            sourceButton("Import Files", detail: "Select audio files", symbol: "doc.badge.plus",
                         identifier: "aeon.library.import.files", action: selectFiles)
            Divider().overlay(AeonTheme.ColorToken.rule)
            sourceButton("Import Folder", detail: "Include music in subfolders", symbol: "folder.badge.plus",
                         identifier: "aeon.library.import.folder", action: selectFolder)
        }
        .background(AeonTheme.ColorToken.surfaceSelected.opacity(0.35))
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: 0.5))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func sourceButton(_ title: String, detail: String, symbol: String,
                              identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                    Text(detail).font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct AeonImportStatus: View {
    let progress: LibraryImportProgress?
    let result: LibraryImportResult?
    let cancel: () -> Void

    var body: some View {
        if let progress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(progressLabel(progress)).font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                    Spacer(minLength: 8)
                    Button("Pause", action: cancel)
                        .font(AeonTheme.FontToken.ui(.callout))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("aeon.library.import.cancel")
                }
                if progress.totalFiles == 0 {
                    ProgressView().tint(AeonTheme.ColorToken.textPrimary)
                } else {
                    ProgressView(value: fraction(progress)).tint(AeonTheme.ColorToken.textPrimary)
                }
            }
            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            .accessibilityIdentifier("aeon.library.import.progress")
        } else if let result {
            VStack(alignment: .leading, spacing: 6) {
                Text(resultTitle(result)).font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
                Text(resultDetail(result)).font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AeonTheme.ColorToken.surfaceSelected.opacity(0.4))
            .accessibilityIdentifier("aeon.library.import.result")
        }
    }

    private func fraction(_ value: LibraryImportProgress) -> Double {
        if value.totalGroups > 0 {
            return Double(value.completedGroups) / Double(value.totalGroups)
        }
        return Double(value.completedFiles) / Double(max(1, value.totalFiles))
    }

    private func progressLabel(_ value: LibraryImportProgress) -> String {
        switch value.phase {
        case .scanning: return "Scanning your selection…"
        case .readingMetadata: return "Reading files: \(value.completedFiles) of \(value.totalFiles)"
        case .grouping: return "Organizing albums…"
        case .committing: return "Adding albums: \(value.completedGroups) of \(value.totalGroups)"
        case .complete: return "Import complete"
        }
    }

    private func resultTitle(_ value: LibraryImportResult) -> String {
        if value.importedTracks > 0 {
            return "Added \(value.importedTracks) \(value.importedTracks == 1 ? "track" : "tracks")"
        }
        return value.skippedDuplicateAlbums.isEmpty ? "No tracks imported" : "Already in your library"
    }

    private func resultDetail(_ value: LibraryImportResult) -> String {
        var parts: [String] = []
        if value.importedAlbums > 0 {
            parts.append("\(value.importedAlbums) \(value.importedAlbums == 1 ? "album" : "albums") added.")
        }
        if !value.skippedDuplicateAlbums.isEmpty {
            parts.append("\(value.skippedDuplicateAlbums.count) existing albums skipped.")
        }
        if !value.failedFiles.isEmpty {
            parts.append("\(value.failedFiles.count) files could not be read or played. Check the format and that the files have downloaded.")
        }
        return parts.isEmpty ? "The selection produced no playable audio. Try another file or folder." : parts.joined(separator: " ")
    }
}

enum AeonRecoveryBuildIdentity {
    static var label: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["AeonBuildCommit"] as? String ?? "local"
        return "Recovery 1 · \(commit.prefix(8))"
    }
}
'''

root = 'ios/App/App/Features/Root/AeonRootView.swift'
replace(root, '    @State private var picker: ImportPickerKind?',
        '    @State private var picker: ImportPickerKind?\n    @State private var pendingImport: PendingImportSelection?')
replace(root, '.sheet(item: $picker) { kind in', '.sheet(item: $picker, onDismiss: finishPickerDismissal) { kind in')
replace(root, '''                picker = nil
                handle(outcome, kind: kind)''', '''                pendingImport = PendingImportSelection(kind: kind, outcome: outcome)
                picker = nil''')
replace(root, '    private func handle(_ outcome: ImportPickerOutcome, kind: ImportPickerKind) {', '''    private func finishPickerDismissal() {
        guard let selection = pendingImport else { return }
        pendingImport = nil
        withExtendedLifetime(selection) {
            handle(selection.outcome, kind: selection.kind)
        }
    }

    private func handle(_ outcome: ImportPickerOutcome, kind: ImportPickerKind) {''')
replace(root, '    let container: AppContainer', '    @ObservedObject var container: AppContainer')
# Keep the existing iPad layout; iPhone navigation now owns its safe-area inset.
a = sources[root].index('    var body: some View {', sources[root].index('private struct AeonReadyShell'))
b = sources[root].index('    private var effectiveReduceMotion', a)
old_body = sources[root][a:b]
x = old_body.index('            AeonScreen(')
y = old_body.index('\n        }\n        .animation', x)
regular = textwrap.dedent(old_body[x:y]).rstrip()
new_body = r'''    var body: some View {
        AeonArtworkTintHost(playback: playback, catalog: services.catalogRepository,
                            artworkStore: services.artworkStore) {
            if horizontalSizeClass == .compact {
                compactShell
            } else {
                regularShell
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
        .onChange(of: container.libraryImportResult) { result in
            guard result != nil else { return }
            libraryController.reload(reset: true)
            destination = .library
            nowPlayingVisible = false
        }
    }

    private var compactShell: some View {
        ZStack {
            SkyScreen(
                controller: services.skySceneController,
                importProgress: importProgress,
                importError: importError,
                readableInsets: AeonReadableInsets(),
                showHUD: settingsController.preferences.hud,
                highContrast: settingsController.preferences.highSkyContrast,
                reduceMotionOverride: settingsController.preferences.reduceMotion,
                importFiles: importFiles,
                importFolder: importFolder
            )
            .allowsHitTesting(destination == .sky && !nowPlayingVisible)
            .accessibilityHidden(destination != .sky || nowPlayingVisible)

            if destination != .sky {
                compactDestination
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AeonTheme.ColorToken.void)
                    .allowsHitTesting(!nowPlayingVisible)
                    .accessibilityHidden(nowPlayingVisible)
            }
            if nowPlayingVisible {
                NowPlayingView(
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AeonTheme.ColorToken.void)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !nowPlayingVisible {
                VStack(spacing: 0) {
                    if playback.snapshot?.trackID != nil {
                        PlayerBar(playback: playback, catalog: services.catalogRepository,
                                  artworkStore: services.artworkStore, open: {
                            nowPlayingSection = nil
                            nowPlayingVisible = true
                        })
                        .frame(minHeight: AeonTheme.Space.playerBar)
                    }
                    AeonCompactNavigation(destination: $destination)
                }
                .background(AeonTheme.ColorToken.chamber.ignoresSafeArea(edges: .bottom))
            }
        }
    }

    @ViewBuilder
    private var compactDestination: some View {
        switch destination {
        case .library:
            LibraryScreen(
                controller: libraryController,
                importProgress: importProgress,
                importError: importError,
                importFiles: importFiles,
                importFolder: importFolder,
                findInSky: { id, reduced in
                    libraryController.findInSky(id: id, reduceMotion: reduced)
                    destination = .sky
                },
                importResult: container.libraryImportResult,
                cancelImport: container.cancelLibraryImport
            )
        case .playlists:
            PlaylistsScreen(controller: playlistsController)
        case .settings:
            SettingsScreen(controller: settingsController) { section in
                nowPlayingSection = section
                nowPlayingVisible = true
            }
        case .sky:
            EmptyView()
        }
    }

    private var regularShell: some View {
'''
new_body += textwrap.indent(regular, '        ') + '\n    }\n\n'
sources[root] = sources[root][:a] + new_body + sources[root][b:]

container = 'ios/App/App/AppContainer.swift'
replace(container, '        libraryImportTask = Task { [weak self] in', '''        let accessLease = ImportAccessLease(urls: urls)
        libraryImportTask = Task { [weak self, accessLease] in
            defer { withExtendedLifetime(accessLease) {} }''')

library = 'ios/App/App/Features/Library/LibraryScreen.swift'
replace(library, '    let findInSky: (String, Bool) -> Void', '''    let findInSky: (String, Bool) -> Void
    var importResult: LibraryImportResult? = nil
    var cancelImport: () -> Void = {}''')
replace(library, '    @State private var importSheetPresented = false\n', '')
replace(library, '''        .sheet(isPresented: $importSheetPresented) {
            AeonImportSheet(selectFiles: importFiles, selectFolder: importFolder)
        }
''', '')
replace(library, '                    if let importProgress { importStatus(importProgress) }',
        '                    AeonImportStatus(progress: importProgress, result: importResult, cancel: cancelImport)')
block(library, '    private var header: some View {', '    private var controls: some View {', r'''    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library")
                    .font(AeonTheme.FontToken.ui(.title, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                Spacer()
                Text("\(controller.totalCount) \(controller.totalCount == 1 ? "album" : "albums")")
                    .font(AeonTheme.FontToken.ui(.subheadline))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .accessibilityIdentifier("aeon.library.count")
            }
            if hasLibraryContent {
                AeonImportActions(selectFiles: importFiles, selectFolder: importFolder,
                                  disabled: importProgress != nil)
            }
        }
    }

''')
block(library, '    private var emptyLibrary: some View {', '    private func albumGrid(width: CGFloat) -> some View {', r'''    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "square.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Add your first album")
                    .font(AeonTheme.FontToken.ui(.title3, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                Text("Choose audio files or a folder. Your originals stay where they are.")
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AeonImportActions(selectFiles: importFiles, selectFolder: importFolder,
                              disabled: importProgress != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .accessibilityIdentifier("aeon.library.empty")
    }

''')

sky = 'ios/App/App/Features/Sky/SkyScreen.swift'
replace(sky, '    @State private var importSheetPresented = false\n', '')
replace(sky, '    @Environment(\\.accessibilityReduceMotion) private var reduceMotion',
        '    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n    @Environment(\\.horizontalSizeClass) private var horizontalSizeClass')
replace(sky, '''        .sheet(isPresented: $importSheetPresented) {
            AeonImportSheet(selectFiles: importFiles, selectFolder: importFolder)
        }
''', '')
replace(sky, '.padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))',
        '.padding(.top, horizontalSizeClass == .compact ? AeonTheme.Space.small : max(AeonTheme.Space.small, geometry.safeAreaInsets.top))')
block(sky, '    private var emptyState: some View {', '    private var effectiveReduceMotion: Bool {', r'''    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your music, mapped.")
                    .font(AeonTheme.FontToken.ui(.title, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                Text("Add an album to start your sky.")
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            AeonImportActions(selectFiles: importFiles, selectFolder: importFolder,
                              disabled: importProgress != nil)
            if let progress = importProgress {
                ProgressView().tint(AeonTheme.ColorToken.textPrimary)
                Text(progress.totalFiles == 0 ? "Scanning your selection…" : "Reading \(progress.completedFiles) of \(progress.totalFiles) files")
                    .font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            if let importError, !importError.isEmpty {
                Text(importError)
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("aeon.sky.import.error")
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.empty")
    }

''')

chrome = 'ios/App/App/DesignSystem/AeonChrome.swift'
sources[chrome] += r'''

/// The system owns the home-indicator inset; only this 52-point row consumes content.
struct AeonCompactNavigation: View {
    @Binding var destination: AeonDestination
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AeonDestination.allCases) { item in
                Button { destination = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item == .playlists ? "music.note.list" : item.symbol)
                            .font(.system(size: 19, weight: destination == item ? .semibold : .regular))
                            .frame(height: 22)
                        if !dynamicTypeSize.isAccessibilitySize && !AeonTestOverrides.accessibilityText {
                            Text(item.rawValue.capitalized)
                                .font(AeonTheme.FontToken.ui(.caption2, weight: destination == item ? .semibold : .regular))
                        }
                    }
                    .foregroundStyle(destination == item ? AeonTheme.ColorToken.textPrimary : AeonTheme.ColorToken.boneTertiary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue.capitalized)
                .accessibilityAddTraits(destination == item ? .isSelected : [])
                .accessibilityIdentifier("aeon.navigation.\(item.rawValue)")
            }
        }
        .frame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: 0.5) }
        .accessibilityIdentifier("aeon.navigation.compact")
    }
}
'''

theme = 'ios/App/App/DesignSystem/AeonTheme.swift'
for before, after in [
    ('// Core editorial palette from the Aeon 5 product-design handoff.', '// Recovery palette: neutral silver and white; keep the sky renderer unchanged.'),
    ('Color(red: 242 / 255, green: 236 / 255, blue: 217 / 255)', 'Color.white.opacity(0.96)'),
    ('Color(red: 216 / 255, green: 208 / 255, blue: 185 / 255)', 'Color.white.opacity(0.76)'),
    ('Color(red: 244 / 255, green: 242 / 255, blue: 236 / 255)', 'Color.white.opacity(0.96)'),
    ('static let section: CGFloat = 40', 'static let section: CGFloat = 24'),
    ('static let hero: CGFloat = 48', 'static let hero: CGFloat = 24'),
    ('static let compactDock: CGFloat = 74', 'static let compactDock: CGFloat = 52'),
    ('static let playerBar: CGFloat = 72', 'static let playerBar: CGFloat = 60'),
    ('static let compact: CGFloat = 14', 'static let compact: CGFloat = 4'),
    ('static let control: CGFloat = 16', 'static let control: CGFloat = 4'),
    ('static let surface: CGFloat = 18', 'static let surface: CGFloat = 6'),
]:
    replace(theme, before, after)

components = 'ios/App/App/DesignSystem/AeonComponents.swift'
replace(components, '''            .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
            .tracking(1.2)''', '''            .font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
            .tracking(0)''')
block(components, 'struct AeonEmptyState: View {', 'struct AeonRouteMark: View {', r'''struct AeonEmptyState: View {
    let title: String
    let detail: String?
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(AeonTheme.FontToken.ui(.title3, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
            }
        }
        .foregroundStyle(AeonTheme.ColorToken.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

''')
block(components, 'struct AeonImportSheet: View {', 'struct AeonToast: View {', '')

settings = 'ios/App/App/Features/Settings/SettingsScreen.swift'
replace(settings, '                        AeonBreadcrumb(text: "Aeon / Preferences")\n', '')
replace(settings, '                        AeonDisplayText("Settings", size: 42, maximumLines: 1)',
        '                        Text("Settings").font(AeonTheme.FontToken.ui(.title, weight: .semibold))')
replace(settings, '                            .accessibilityIdentifier("aeon.settings.screen")', '''                            .accessibilityIdentifier("aeon.settings.screen")
                        Text(AeonRecoveryBuildIdentity.label)
                            .font(AeonTheme.FontToken.ui(.caption))
                            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                            .accessibilityIdentifier("aeon.settings.build-identity")''')
block(settings, '    private var sleepTimerSelector: some View {', '    private func settingsSection<Content: View>', r'''    private var sleepTimerSelector: some View {
        HStack {
            Text("Duration")
                .font(AeonTheme.FontToken.ui(.callout))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            Spacer()
            Picker("Sleep timer", selection: Binding(get: { controller.sleepTimer }, set: controller.setSleepTimer)) {
                ForEach(SettingsSleepTimer.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .tint(AeonTheme.ColorToken.textPrimary)
            .accessibilityIdentifier("aeon.settings.sleep.selector")
        }
        .frame(minHeight: 44)
    }

''')

playlists = 'ios/App/App/Features/Playlists/PlaylistsScreen.swift'
replace(playlists, '                AeonBreadcrumb(text: "Routes")\n', '')
replace(playlists, '                AeonDisplayText("Playlists", size: 42, maximumLines: 1)',
        '                Text("Playlists").font(AeonTheme.FontToken.ui(.title, weight: .semibold))')
replace(playlists, 'title: "No routes charted yet."', 'title: "No playlists yet"')
replace(playlists, 'detail: "Build a route through the records you return to."',
        'detail: "Keep the tracks you return to together."')
replace(playlists, 'Button("CREATE PLAYLIST") { creationPresented = true }', 'Button("Create Playlist") { creationPresented = true }')
replace(playlists, '''                        .buttonStyle(AeonButtonStyle(tier: .filled))
                        .frame(maxWidth: 320)''', '''                        .buttonStyle(AeonButtonStyle(tier: .hairline))
                        .frame(maxWidth: 220)''')
replace(playlists, '                Spacer(minLength: AeonTheme.Space.section)', '                Spacer(minLength: 16)', count=2)
replace(playlists, '            if controller.playlists.isEmpty {\n                Spacer(minLength: 16)',
        '            if controller.playlists.isEmpty {\n                Color.clear.frame(height: 24)')
replace(playlists, '                        AeonDisplayText("Chart a playlist", size: 32, maximumLines: 2)',
        '                        Text("New playlist").font(AeonTheme.FontToken.ui(.title2, weight: .semibold))')
replace(playlists, '                        AeonLabel(text: "New route")\n', '')
replace(playlists, 'Give this route a name. Tracks can be added from albums afterward.',
        'Choose a name, then add tracks from your albums.')
replace(playlists, '.presentationDetents([.height(310)])', '.presentationDetents([.medium, .large])')

app = 'ios/App/App/AeonApp.swift'
replace(app, '        let deterministicFixture = arguments.contains("-AeonSkyFixture")',
        '        let deterministicFixture = arguments.contains("-AeonImportSmokeTesting")\n            || arguments.contains("-AeonSkyFixture")')

tests = 'ios/App/AppUITests/ImportPickerPresentationTests.swift'
sources[tests] = r'''import XCTest

/// Use the real system picker, not a mocked URL callback. Launch isolation only
/// affects storage. Actual provider selection and audio playback still need a device.
final class ImportPickerPresentationTests: XCTestCase {
    func testImportFilesPresentsTheSystemDocumentPicker() {
        checkPicker(source: "files", fromLibrary: false)
    }

    func testImportFolderPresentsTheSystemDocumentPicker() {
        checkPicker(source: "folder", fromLibrary: false)
    }

    func testLibraryFilesPresentsTheSystemDocumentPicker() {
        checkPicker(source: "files", fromLibrary: true)
    }

    func testLibraryFolderPresentsTheSystemDocumentPicker() {
        checkPicker(source: "folder", fromLibrary: true)
    }

    func testCancellingAPickerLeavesNoImportErrorBehind() {
        let app = launch()
        for source in ["files", "folder", "files"] {
            let button = app.buttons["aeon.library.import.\(source)"]
            XCTAssertTrue(waitUntilHittable(button))
            button.tap()
            guard let cancel = waitForPicker(over: app) else {
                XCTFail("System picker did not open on repeated \(source) selection")
                return
            }
            cancel.tap()
            XCTAssertTrue(waitUntilHittable(button))
            XCTAssertFalse(app.alerts.element.exists)
            XCTAssertFalse(app.descendants(matching: .any)["aeon.sky.import.error"].exists)
        }
    }

    func testRecoveryScreensKeepNavigationCompact() {
        let app = launch()
        for destination in ["sky", "library", "playlists", "settings"] {
            let button = app.buttons["aeon.navigation.\(destination)"]
            XCTAssertTrue(waitUntilHittable(button))
            button.tap()
            let dock = app.descendants(matching: .any)["aeon.navigation.compact"].firstMatch
            XCTAssertTrue(dock.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(dock.frame.height, 60, "Tab row grew beyond its intended height")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "recovery-1-\(destination)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(app.staticTexts["aeon.settings.build-identity"].exists)
    }

    private func checkPicker(source: String, fromLibrary: Bool) {
        let app = launch()
        if fromLibrary {
            let library = app.buttons["aeon.navigation.library"]
            XCTAssertTrue(waitUntilHittable(library))
            library.tap()
        }
        let identifier = "aeon.library.import.\(source)"
        let button = app.buttons[identifier]
        XCTAssertTrue(waitUntilHittable(button))
        XCTAssertEqual(app.buttons.matching(identifier: identifier).count, 1,
                       "A hidden Sky action leaked through the Library accessibility tree")
        button.tap()
        guard let cancel = waitForPicker(over: app) else {
            XCTFail("\(source) import did not present a cancellable system Files picker")
            return
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "picker-\(fromLibrary ? "library" : "sky")-\(source)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(waitUntilHittable(button))
        XCTAssertFalse(app.alerts.element.exists)
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    private func waitForPicker(over app: XCUIApplication) -> XCUIElement? {
        let remote = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for candidate in [app, remote] {
                let cancel = candidate.buttons["Cancel"].firstMatch
                if cancel.exists && cancel.isHittable { return cancel }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AeonImportSmokeTesting"]
        app.launch()
        return app
    }
}
'''

changed = []
for path, source in sources.items():
    assert not source.endswith('\\'), f'Truncated Swift source: {path}'
    assert source.count('AeonImportSheet(') == 0, f'Old chooser survived in {path}'
    if source != Path(path).read_text():
        Path(path).write_text(source)
        changed.append(path)

MANIFEST.parent.mkdir(parents=True, exist_ok=True)
MANIFEST.write_text(json.dumps({'iteration': 1, 'baseline': PIN,
                               'sha256': {p: digest(p) for p in changed}}, indent=2) + '\n')
print('RECOVERY_CHANGED_FILES ' + json.dumps(changed))
for path in Path('ios/App/AppUITests').glob('*.swift'):
    if path.as_posix() == tests:
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if 'aeon.import.sheet' in line or '"aeon.library.import"' in line or 'aeon.settings.sleep.' in line:
            print(f'REVIEW_TEST_CONTRACT {path}:{number}: {line.strip()}')
