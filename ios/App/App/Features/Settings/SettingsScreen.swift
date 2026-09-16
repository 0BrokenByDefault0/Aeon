import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsScreen: View {
    @ObservedObject var controller: SettingsController
    let openNowPlaying: (NowPlayingSection) -> Void
    let contentBottomInset: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        GeometryReader { geometry in
            let horizontalInset = geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                        AeonBreadcrumb(text: "Aeon / Preferences")
                        AeonDisplayText("Settings", size: AeonTheme.FontToken.Display.screen, maximumLines: 1)
                            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                            .accessibilityIdentifier("aeon.settings.screen")
                    }

                    settingsSection("Playback") {
                        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
                            settingText(title: "Sleep timer", detail: "Fades out, then stops.")
                            sleepTimerSelector
                            if !controller.sleepStatus.isEmpty { note(controller.sleepStatus) }
                        }
                        .padding(.bottom, AeonTheme.Space.small)
                        .rowDivider()

                        settingsNavigationRow(
                            title: "Equalizer",
                            detail: "Ten bands, ±12 dB. Adjust it where you can hear the result.",
                            identifier: "aeon.settings.eq.open"
                        ) { openNowPlaying(.equalizer) }

                        settingsNavigationRow(
                            title: "Spectrum",
                            detail: "Star glow and nebula breath follow the music.",
                            identifier: "aeon.settings.spectrum.open"
                        ) { openNowPlaying(.spectrum) }
                    }

                    settingsSection("Library") {
                        nativeToggle(
                            title: "One import, one album",
                            detail: "Files picked together become one album; only separate folders split them. Turn off to let album tags divide files instead.",
                            isOn: Binding(get: { controller.preferences.oneImportOneAlbum }, set: controller.setOneImportOneAlbum),
                            identifier: "aeon.settings.import-grouping"
                        )

                        nativeToggle(
                            title: "Automatic metadata lookups",
                            detail: "Off by default. When enabled, missing album titles and artist names are sent to Apple and MusicBrainz after an import to find tags and artwork. Only those words are sent, never your files.",
                            isOn: Binding(get: { controller.preferences.metadataLookups }, set: controller.setMetadataLookups),
                            identifier: "aeon.settings.metadata-lookups"
                        )

                        settingRow(title: "Artwork", detail: "Re-checks every cover. Interrupted work resumes where it stopped.") {
                            Button("REPAIR") { controller.repairArtwork() }
                                .buttonStyle(AeonButtonStyle(tier: .hairline))
                                .frame(maxWidth: 120)
                                .accessibilityIdentifier("aeon.settings.artwork-repair")
                        }

                        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                            settingRow(title: "Storage", detail: "This device only.") {
                                Button("MEASURE") { controller.measureStorage() }
                                    .buttonStyle(AeonButtonStyle(tier: .bare))
                                    .frame(maxWidth: 116)
                            }
                            AeonProgressBar(value: max(0.015, controller.storage.fraction))
                            Text(storageText)
                                .font(AeonTheme.FontToken.metric(.caption))
                                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("aeon.settings.storage-value")
                        }
                        .padding(.bottom, AeonTheme.Space.small)
                    }

                    settingsSection("The Sky") {
                        nativeToggle(
                            title: "Heads-up display",
                            detail: "Census readout over the sky.",
                            isOn: Binding(get: { controller.preferences.hud }, set: controller.setHUD),
                            identifier: "aeon.settings.hud"
                        )
                        nativeToggle(
                            title: "Sky contrast",
                            detail: "Raises labels and glass edges without bleaching the atmosphere.",
                            isOn: Binding(get: { controller.preferences.highSkyContrast }, set: controller.setHighSkyContrast),
                            identifier: "aeon.settings.sky-contrast"
                        )
                        nativeToggle(
                            title: "Reduce motion",
                            detail: "Cross-fades sky travel and stills reactive movement.",
                            isOn: Binding(get: { controller.preferences.reduceMotion }, set: controller.setReduceMotion),
                            identifier: "aeon.settings.reduce-motion"
                        )
                    }

                    footer
                }
                .frame(
                    width: max(0, geometry.size.width - (horizontalInset * 2)),
                    alignment: .leading
                )
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, AeonTheme.Space.regular)
                .padding(.bottom, contentBottomInset + AeonTheme.Space.edge)
            }
            .scrollIndicators(.hidden)
        }
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
                    AeonDisplayText("Erase Everything?", size: AeonTheme.FontToken.Display.name, maximumLines: 2)
                        .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    Text("This removes Aeon’s catalogue, artwork, playlists, listening history, and copied audio from this device. Files Aeon adopted in place are not deleted.")
                        .font(AeonTheme.FontToken.ui(.body))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    TextField("Type ERASE", text: $eraseText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, AeonTheme.Space.regular)
                        .frame(minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                                .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.62))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                                .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
                        )
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

    private var sleepTimerSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AeonTheme.Space.small) {
                ForEach(SettingsSleepTimer.allCases) { value in
                    Button { controller.setSleepTimer(value) } label: {
                        Text(value.label)
                            .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                            .foregroundStyle(controller.sleepTimer == value ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                            .padding(.horizontal, AeonTheme.Space.regular)
                            .frame(minHeight: AeonTheme.Space.minimumTarget)
                            .background(
                                Capsule()
                                    .fill(controller.sleepTimer == value
                                        ? AeonTheme.ColorToken.bone
                                        : AeonTheme.ColorToken.surfaceSelected.opacity(0.66))
                            )
                            .overlay(
                                Capsule().stroke(
                                    controller.sleepTimer == value ? .clear : AeonTheme.ColorToken.rule,
                                    lineWidth: AeonTheme.Stroke.hairline
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(controller.sleepTimer == value ? .isSelected : [])
                    .accessibilityIdentifier("aeon.settings.sleep.\(value.rawValue)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
            AeonLabel(text: title)
                .accessibilityIdentifier("aeon.settings.section.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            content()
        }
        .padding(.top, AeonTheme.Space.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
        }
    }

    private func nativeToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        identifier: String
    ) -> some View {
        Toggle(isOn: isOn) {
            settingText(title: title, detail: detail)
        }
        .toggleStyle(.switch)
        .tint(AeonTheme.ColorToken.bone)
        .padding(.vertical, AeonTheme.Space.small)
        .rowDivider()
        .accessibilityIdentifier(identifier)
    }

    private func settingsNavigationRow(
        title: String,
        detail: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: AeonTheme.Space.regular) {
                settingText(title: title, detail: detail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, AeonTheme.Space.small)
        .rowDivider()
        .accessibilityIdentifier(identifier)
    }

    private func settingRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                    settingText(title: title, detail: detail)
                    trailing()
                }
            } else {
                HStack(alignment: .center, spacing: AeonTheme.Space.regular) {
                    settingText(title: title, detail: detail)
                    Spacer(minLength: AeonTheme.Space.small)
                    trailing()
                }
            }
        }
        .padding(.vertical, AeonTheme.Space.small)
        .frame(minHeight: 62)
        .rowDivider()
    }

    private func settingText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
            Text(title)
                .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            Text(detail)
                .font(AeonTheme.FontToken.ui(.caption))
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ value: String) -> some View {
        Text(value)
            .font(AeonTheme.FontToken.metric(.caption))
            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
            Text("Restore by choosing a full backup zip. Catalogue exports contain tags, playlists, history, queue, and sky records without audio or artwork bytes.")
                .font(AeonTheme.FontToken.metric(.caption))
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: actionColumns(minimum: 160), spacing: AeonTheme.Space.small) {
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
            Group {
                if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                        eraseDescription
                        eraseButton
                    }
                } else {
                    HStack {
                        eraseDescription
                        Spacer()
                        eraseButton
                    }
                }
            }
            .padding(.top, AeonTheme.Space.small)
            Text("AEON / 5.0 · YOUR MUSIC, YOUR DEVICE")
                .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, AeonTheme.Space.large)
        }
        .padding(.top, AeonTheme.Space.large)
    }

    private var eraseDescription: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
            Text("Erase everything")
                .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("Albums, audio, playlists, and the log — the sky goes dark.")
                .font(AeonTheme.FontToken.ui(.caption))
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionColumns(minimum: CGFloat) -> [GridItem] {
        if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
            return [GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: minimum), spacing: AeonTheme.Space.small)]
    }

    private var eraseButton: some View {
        Button { eraseText = ""; erasePresented = true } label: {
            if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .regular))
            } else {
                Text("ERASE")
            }
        }
        .buttonStyle(AeonButtonStyle(tier: .bare, destructive: true))
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText ? .infinity : 112)
        .accessibilityLabel("Erase everything")
        .accessibilityIdentifier("aeon.settings.erase")
    }

    private var storageText: String {
        "\(format(controller.storage.usedBytes)) used · \(format(controller.storage.libraryBytes)) music · \(format(controller.storage.availableBytes)) available"
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension View {
    func rowDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(AeonTheme.ColorToken.rule)
                .frame(height: AeonTheme.Stroke.hairline)
        }
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
