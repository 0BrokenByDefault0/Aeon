import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsScreen: View {
    @ObservedObject var controller: SettingsController
    let openNowPlaying: (NowPlayingSection) -> Void
    let contentBottomInset: CGFloat
    @State private var restoring = false
    @State private var erasePresented = false
    @State private var eraseText = ""

    init(
        controller: SettingsController,
        contentBottomInset: CGFloat = 0,
        openNowPlaying: @escaping (NowPlayingSection) -> Void
    ) {
        self.controller = controller
        self.contentBottomInset = contentBottomInset
        self.openNowPlaying = openNowPlaying
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                VStack(alignment: .leading, spacing: 2) {
                    AeonBreadcrumb(text: "Aeon / Preferences")
                    AeonDisplayText("Settings", size: 42, maximumLines: 1)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                        .accessibilityIdentifier("aeon.settings.screen")
                }
                settingsSection("Playback") {
                    settingRow(title: "Sleep timer", detail: "Fades out, then stops.") {
                        EmptyView()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(SettingsSleepTimer.allCases) { value in
                            Button(value.label) { controller.setSleepTimer(value) }
                                .buttonStyle(AeonButtonStyle(tier: controller.sleepTimer == value ? .filled : .hairline))
                                .accessibilityAddTraits(controller.sleepTimer == value ? .isSelected : [])
                                .accessibilityIdentifier("aeon.settings.sleep.\(value.rawValue)")
                        }
                    }
                    if !controller.sleepStatus.isEmpty { note(controller.sleepStatus) }
                    settingRow(title: "Equalizer", detail: "Ten bands, ±12 dB. Adjust it where you can hear the result.") {
                        HStack(spacing: 0) {
                            Button("OPEN") { openNowPlaying(.equalizer) }
                                .buttonStyle(AeonButtonStyle(tier: .bare))
                                .accessibilityIdentifier("aeon.settings.eq.open")
                            Button("RESET") { controller.resetEQ() }
                                .buttonStyle(AeonButtonStyle(tier: .bare))
                                .accessibilityIdentifier("aeon.settings.eq.reset")
                        }
                    }
                    settingRow(title: "Spectrum", detail: "Star glow and nebula breath follow the music.") {
                        HStack(spacing: 0) {
                            Button("OPEN") { openNowPlaying(.spectrum) }
                                .buttonStyle(AeonButtonStyle(tier: .bare))
                                .accessibilityIdentifier("aeon.settings.spectrum.open")
                            Button("RESET") { controller.resetSpectrum() }
                                .buttonStyle(AeonButtonStyle(tier: .bare))
                        }
                    }
                }

                settingsSection("Library") {
                    Toggle(
                        isOn: Binding(get: { controller.preferences.oneImportOneAlbum }, set: controller.setOneImportOneAlbum)
                    ) {
                        settingText(
                            title: "One import, one album",
                            detail: "Files picked together become one album; only separate folders split them. Turn off to let album tags divide files instead."
                        )
                    }
                    .toggleStyle(AeonToggleStyle())
                    .accessibilityIdentifier("aeon.settings.import-grouping")
                    Toggle(
                        isOn: Binding(get: { controller.preferences.metadataLookups }, set: controller.setMetadataLookups)
                    ) {
                        settingText(
                            title: "Automatic metadata lookups",
                            detail: "Off by default. When enabled, missing album titles and artist names are sent to Apple and MusicBrainz after an import to find tags and artwork. Only those words are sent, never your files."
                        )
                    }
                    .toggleStyle(AeonToggleStyle())
                    .accessibilityIdentifier("aeon.settings.metadata-lookups")
                    settingRow(title: "Artwork", detail: "Re-checks every cover. Interrupted work resumes where it stopped.") {
                        Button("REPAIR") { controller.repairArtwork() }
                            .buttonStyle(AeonButtonStyle(tier: .hairline))
                            .accessibilityIdentifier("aeon.settings.artwork-repair")
                    }
                    VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                        settingRow(title: "Storage", detail: "This device only.") {
                            Button("MEASURE") { controller.measureStorage() }
                                .buttonStyle(AeonButtonStyle(tier: .bare))
                        }
                        AeonProgressBar(value: max(0.015, controller.storage.fraction))
                        Text(storageText)
                            .font(AeonTheme.FontToken.metric(.caption))
                            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                            .accessibilityIdentifier("aeon.settings.storage-value")
                    }
                }

                settingsSection("The Sky") {
                    Toggle(
                        isOn: Binding(get: { controller.preferences.hud }, set: controller.setHUD)
                    ) { settingText(title: "Heads-up display", detail: "Census readout over the sky.") }
                    .toggleStyle(AeonToggleStyle())
                    .accessibilityIdentifier("aeon.settings.hud")
                    Toggle(
                        isOn: Binding(get: { controller.preferences.highSkyContrast }, set: controller.setHighSkyContrast)
                    ) { settingText(title: "Sky contrast", detail: "Raises labels and glass edges without bleaching the atmosphere.") }
                    .toggleStyle(AeonToggleStyle())
                    .accessibilityIdentifier("aeon.settings.sky-contrast")
                    Toggle(
                        isOn: Binding(get: { controller.preferences.reduceMotion }, set: controller.setReduceMotion)
                    ) { settingText(title: "Reduce motion", detail: "Cross-fades sky travel and stills reactive movement.") }
                    .toggleStyle(AeonToggleStyle())
                    .accessibilityIdentifier("aeon.settings.reduce-motion")
                }

                footer
            }
            .padding(.horizontal, AeonTheme.Space.edge)
            .padding(.vertical, AeonTheme.Space.medium)
            .padding(.bottom, contentBottomInset + AeonTheme.Space.edge)
        }
        .scrollIndicators(.hidden)
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            controller.restore(from: url)
        }
        .sheet(isPresented: Binding(
            get: { controller.exportURL != nil },
            set: { if !$0 { controller.clearExport() } }
        )) {
            if let url = controller.exportURL {
                DocumentExportPicker(url: url, completion: controller.clearExport)
            }
        }
        .sheet(isPresented: $erasePresented) {
            AeonSheet {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    AeonDisplayText("Erase Everything?", size: 30, maximumLines: 2)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                    Text("This removes Aeon’s catalogue, artwork, playlists, listening history, and copied audio from this device. Files Aeon adopted in place are not deleted.")
                        .font(AeonTheme.FontToken.ui(.body))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    TextField("Type ERASE", text: $eraseText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, AeonTheme.Space.medium)
                        .frame(minHeight: 44)
                        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: 0.5))
                        .accessibilityIdentifier("aeon.settings.erase-confirmation")
                    Button("Erase Everything") {
                        if controller.eraseEverything(confirmation: eraseText) { erasePresented = false }
                    }
                    .buttonStyle(AeonButtonStyle(tier: .hairline, destructive: true))
                    .disabled(eraseText != "ERASE")
                    .accessibilityIdentifier("aeon.settings.erase-commit")
                    Button("CANCEL") { erasePresented = false }
                        .buttonStyle(AeonButtonStyle(tier: .bare))
                }
                .padding(AeonTheme.Space.edge)
            }
            .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if let message = controller.operationMessage {
                AeonToast(message: message).padding(AeonTheme.Space.edge)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            AeonLabel(text: title)
                .accessibilityIdentifier("aeon.settings.section.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            content()
        }
        .padding(.top, AeonTheme.Space.large)
        .overlay(alignment: .top) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
    }

    private func settingRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: AeonTheme.Space.medium) {
            settingText(title: title, detail: detail)
            Spacer(minLength: AeonTheme.Space.small)
            trailing()
        }
        .frame(minHeight: AeonTheme.Space.minimumTarget)
    }

    private func settingText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AeonTheme.FontToken.ui(.body, weight: .medium)).foregroundStyle(AeonTheme.ColorToken.bone)
            Text(detail).font(AeonTheme.FontToken.metric(.caption)).foregroundStyle(AeonTheme.ColorToken.boneTertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ value: String) -> some View {
        Text(value).font(AeonTheme.FontToken.metric(.caption)).foregroundStyle(AeonTheme.ColorToken.boneSecondary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            Text("Restore by choosing a full backup zip. Catalogue exports contain tags, playlists, history, queue, and sky records without audio or artwork bytes.")
                .font(AeonTheme.FontToken.metric(.caption))
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                Button("FULL BACKUP (.ZIP)") { controller.exportFullBackup() }
                    .buttonStyle(AeonButtonStyle(tier: .filled))
                    .accessibilityIdentifier("aeon.settings.backup-full")
                Button("CATALOG ONLY (.JSON)") { controller.exportCatalogue() }
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
                    .accessibilityIdentifier("aeon.settings.backup-catalog")
                Button("RESTORE BACKUP") { restoring = true }
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
                    .accessibilityIdentifier("aeon.settings.restore")
                Button("ACTIVITY LOG") { controller.exportActivity() }
                    .buttonStyle(AeonButtonStyle(tier: .bare))
                    .accessibilityIdentifier("aeon.settings.activity")
                Button("DIAGNOSTICS") { controller.exportDiagnostics() }
                    .buttonStyle(AeonButtonStyle(tier: .bare))
                    .accessibilityIdentifier("aeon.settings.diagnostics")
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Erase everything").font(AeonTheme.FontToken.ui(.body, weight: .medium))
                    Text("Albums, audio, playlists, and the log — the sky goes dark.")
                        .font(AeonTheme.FontToken.metric(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                }
                Spacer()
                Button("ERASE") { eraseText = ""; erasePresented = true }
                    .buttonStyle(AeonButtonStyle(tier: .bare, destructive: true))
                    .accessibilityIdentifier("aeon.settings.erase")
            }
            Text("AEON / 5.0 · YOUR MUSIC, YOUR DEVICE")
                .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, AeonTheme.Space.large)
        }
        .padding(.top, AeonTheme.Space.large)
    }

    private var storageText: String {
        "\(format(controller.storage.usedBytes)) used · \(format(controller.storage.libraryBytes)) music · \(format(controller.storage.availableBytes)) available"
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void
        init(completion: @escaping () -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion() }
    }
}
