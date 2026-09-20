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

    init(controller: SettingsController, contentBottomInset: CGFloat = 0,
         openNowPlaying: @escaping (NowPlayingSection) -> Void) {
        self.controller = controller
        self.contentBottomInset = contentBottomInset
        self.openNowPlaying = openNowPlaying
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                        AeonDisplayText("Settings", size: 42, maximumLines: 1)
                            .foregroundStyle(AeonOrbit.title)
                            .accessibilityIdentifier("aeon.settings.screen")
                    }
                    settingsSection("Playback") {
                        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
                            Text("Sleep timer").font(AeonTheme.FontToken.ui(.callout, weight: .regular))
                                .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                            AeonSegment(
                                values: SettingsSleepTimer.allCases,
                                selection: Binding(get: { controller.sleepTimer }, set: controller.setSleepTimer),
                                label: compactSleepLabel,
                                identifier: { "aeon.settings.sleep.\($0.rawValue)" },
                                spokenLabel: { $0.label }
                            )
                            .accessibilityIdentifier("aeon.settings.sleep.control")
                            note(controller.sleepStatus.isEmpty ? "Fades out, then stops." : controller.sleepStatus)
                        }
                        .padding(.bottom, AeonTheme.Space.regular).rowDivider()
                        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
                            Text("Match loudness").font(AeonTheme.FontToken.ui(.callout, weight: .regular))
                                .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                            AeonSegment(
                                values: ReplayGainMode.allCases,
                                selection: Binding(get: { controller.replayGainMode }, set: controller.setReplayGainMode),
                                label: { $0.label },
                                identifier: { "aeon.settings.replaygain.\($0.rawValue)" },
                                spokenLabel: { $0.spokenLabel }
                            )
                            .accessibilityIdentifier("aeon.settings.replaygain.control")
                            note("Uses ReplayGain tags already in your files, so quiet records stop disappearing between loud ones. Nothing is analysed or written; untagged tracks play untouched.")
                        }
                        .padding(.bottom, AeonTheme.Space.regular).rowDivider()
                        settingsNavigationRow(title: "Equalizer", value: "10 BANDS",
                            detail: "Ten bands, ±12 dB, with automatic headroom so boosts cannot clip.",
                            identifier: "aeon.settings.eq.open", showsDivider: false) { openNowPlaying(.equalizer) }
                    }
                    settingsSection("Library") {
                        orbitalToggle(title: "One import, one album",
                            detail: "Files picked together stay together. Turn off to group by album tags.",
                            isOn: Binding(get: { controller.preferences.oneImportOneAlbum }, set: controller.setOneImportOneAlbum),
                            identifier: "aeon.settings.import-grouping")
                        orbitalToggle(title: "Automatic metadata lookups",
                            detail: "Off by default. When enabled, missing album titles and artist names are sent to Apple and MusicBrainz after an import to find tags and artwork. Only those words are sent, never your files.",
                            isOn: Binding(get: { controller.preferences.metadataLookups }, set: controller.setMetadataLookups),
                            identifier: "aeon.settings.metadata-lookups")
                        settingsNavigationRow(title: "Artwork", value: "REPAIR",
                            detail: "Re-checks covers. Interrupted work resumes where it stopped.",
                            identifier: "aeon.settings.artwork-repair", glyph: .refresh, action: { controller.repairArtwork() })
                        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
                            Button { controller.measureStorage() } label: {
                                labelValue("Storage", value: format(controller.storage.usedBytes))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Measure storage")
                            AeonProgressBar(value: max(0.015, controller.storage.fraction))
                            Text(storageText)
                                .font(AeonTheme.FontToken.metric(.caption))
                                .foregroundStyle(AeonOrbit.secondary)
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("aeon.settings.storage-value")
                        }
                        .padding(.vertical, AeonTheme.Space.regular)
                    }
                    settingsSection("The Sky") {
                        settingsNavigationRow(title: "Spectrum", value: "REACTIVE",
                            detail: "Star glow follows the music.",
                            identifier: "aeon.settings.spectrum.open") { openNowPlaying(.spectrum) }
                        orbitalToggle(title: "Heads-up display", detail: nil,
                            isOn: Binding(get: { controller.preferences.hud }, set: controller.setHUD),
                            identifier: "aeon.settings.hud")
                        orbitalToggle(title: "Sky contrast", detail: nil,
                            isOn: Binding(get: { controller.preferences.highSkyContrast }, set: controller.setHighSkyContrast),
                            identifier: "aeon.settings.sky-contrast")
                        orbitalToggle(title: "Reduce motion", detail: nil,
                            isOn: Binding(get: { controller.preferences.reduceMotion }, set: controller.setReduceMotion),
                            identifier: "aeon.settings.reduce-motion", showsDivider: false)
                    }
                    footer
                }
                .frame(width: max(0, geometry.size.width - inset * 2), alignment: .leading)
                .padding(.horizontal, inset).padding(.vertical, AeonTheme.Space.regular)
                .padding(.bottom, contentBottomInset + AeonTheme.Space.edge)
            }
            .scrollIndicators(.hidden)
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            controller.restore(from: url)
        }
        .sheet(isPresented: Binding(get: { controller.exportURL != nil },
                                    set: { if !$0 { controller.clearExport() } })) {
            if let url = controller.exportURL { DocumentExportPicker(url: url, completion: controller.clearExport) }
        }
        .sheet(isPresented: $erasePresented) {
            AeonSheet {
                ScrollView {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                        AeonDisplayText("Erase Everything?", size: 30, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                        Text("This removes Aeon’s catalogue, artwork, playlists, listening history, and copied audio from this device. Files Aeon adopted in place are not deleted.")
                            .font(AeonTheme.FontToken.ui(.callout)).foregroundStyle(AeonOrbit.secondary)
                        TextField("Type ERASE", text: $eraseText)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .padding(AeonTheme.Space.regular).frame(minHeight: 48)
                            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
                            .accessibilityIdentifier("aeon.settings.erase-confirmation")
                        Button("Erase Everything") {
                            if controller.eraseEverything(confirmation: eraseText) { erasePresented = false }
                        }
                        .buttonStyle(AeonButtonStyle(tier: .hairline, destructive: true))
                        .disabled(eraseText != "ERASE").accessibilityIdentifier("aeon.settings.erase-commit")
                        Button("CANCEL") { erasePresented = false }.buttonStyle(AeonButtonStyle(tier: .bare))
                    }
                    .padding(AeonTheme.Space.edge)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if let message = controller.operationMessage {
                AeonToast(message: message).padding(AeonTheme.Space.edge).padding(.bottom, contentBottomInset)
                    .task {
                        try? await Task.sleep(nanoseconds: UInt64(AeonTheme.Duration.toast * 1_000_000_000))
                        controller.clearMessage()
                    }
            }
        }
        .animation(.easeOut(duration: AeonTheme.Duration.chrome), value: controller.operationMessage)
    }

    private func compactSleepLabel(_ value: SettingsSleepTimer) -> String {
        switch value {
        case .off: return "OFF"
        case .minutes15: return "15M"
        case .minutes30: return "30M"
        case .minutes60: return "60M"
        case .endOfAlbum: return "END"
        }
    }

    private func labelValue(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AeonTheme.Space.regular) {
            Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .regular))
                .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            Spacer(minLength: AeonTheme.Space.small)
            Text(value).font(AeonTheme.FontToken.metric(.caption2)).foregroundStyle(AeonOrbit.secondary)
                .multilineTextAlignment(.trailing)
        }
        .fixedSize(horizontal: false, vertical: true).frame(minHeight: AeonTheme.Space.minimumTarget)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
            AeonLabel(text: title)
                .accessibilityIdentifier("aeon.settings.section.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            content()
        }
        .padding(.top, AeonTheme.Space.large).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
    }

    private func orbitalToggle(title: String, detail: String?, isOn: Binding<Bool>, identifier: String,
                               showsDivider: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            Toggle(isOn: isOn) {
                Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .regular))
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(AeonToggleStyle()).accessibilityIdentifier(identifier)
            if let detail {
                Text(detail).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AeonTheme.Space.small).padding(.bottom, AeonTheme.Space.small)
        .rowDivider(showsDivider)
    }

    private func settingsNavigationRow(title: String, value: String, detail: String?, identifier: String,
                                       glyph: AeonGlyphKind = .disclosure, showsDivider: Bool = true,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                HStack(spacing: AeonTheme.Space.small) {
                    labelValue(title, value: value)
                    AeonGlyph(kind: glyph).foregroundStyle(AeonOrbit.secondary)
                }
                if let detail {
                    Text(detail).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.vertical, AeonTheme.Space.small)
        .rowDivider(showsDivider).accessibilityIdentifier(identifier)
    }

    private var eraseLabel: some View {
        Text("Erase everything").font(AeonTheme.FontToken.ui(.callout, weight: .regular))
            .foregroundStyle(AeonTheme.ColorToken.textPrimary).fixedSize(horizontal: false, vertical: true)
    }

    private var eraseButton: some View {
        Button { eraseText = ""; erasePresented = true } label: {
            AeonGlyph(kind: .erase)
                .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(AeonTheme.ColorToken.danger)
        // The target lives on the Button, not only on its label: a hidden decorative
        // label gives the Button no frame to derive an activation point from, which is
        // what the navigation buttons already avoid.
        .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
        .contentShape(Rectangle())
        .accessibilityLabel("Erase everything").accessibilityIdentifier("aeon.settings.erase")
    }

    private func note(_ value: String) -> some View {
        Text(value).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
    }

    private var footer: some View {
        settingsSection("On this device") {
            note("Restore by choosing a full backup zip. Catalogue exports contain tags, playlists, history, queue, and sky records without audio or artwork bytes.")
            settingsNavigationRow(title: "Full backup", value: "ZIP", detail: nil,
                                  identifier: "aeon.settings.backup-full", glyph: .export, action: { controller.exportFullBackup() })
            settingsNavigationRow(title: "Catalogue only", value: "JSON", detail: nil,
                                  identifier: "aeon.settings.backup-catalog", glyph: .export, action: { controller.exportCatalogue() })
            settingsNavigationRow(title: "Restore backup", value: "CHOOSE", detail: nil,
                                  identifier: "aeon.settings.restore", glyph: .picker) { restoring = true }
            settingsNavigationRow(title: "Activity log", value: "EXPORT", detail: nil,
                                  identifier: "aeon.settings.activity", glyph: .export, action: { controller.exportActivity() })
            settingsNavigationRow(title: "Diagnostics", value: "EXPORT", detail: nil,
                                  identifier: "aeon.settings.diagnostics", glyph: .export, action: { controller.exportDiagnostics() })
            VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                // At accessibility sizes the label alone is wider than the row, so a
                // side-by-side layout pushes the 44pt target past the container's trailing
                // edge: the button still exists but has no valid activation point. Stack
                // the two instead of making them compete for the same line.
                if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                        eraseLabel
                        eraseButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        eraseLabel
                        Spacer(minLength: AeonTheme.Space.small)
                        eraseButton
                    }
                }
                note("Albums, audio, playlists, and the log — the sky goes dark.")
            }
            .padding(.top, AeonTheme.Space.small)
            Text(AeonBuildIdentity.label)
                .font(AeonTheme.FontToken.metric(.caption2)).foregroundStyle(AeonOrbit.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                .accessibilityIdentifier("aeon.settings.build")
                .textSelection(.enabled)
            Text("YOUR MUSIC, YOUR DEVICE")
                .font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.8)
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                .padding(.top, AeonTheme.Space.large)
        }
    }

    private var storageText: String {
        "\(format(controller.storage.usedBytes)) used · \(format(controller.storage.libraryBytes)) music · \(format(controller.storage.availableBytes)) available"
    }
    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private extension View {
    @ViewBuilder func rowDivider(_ shows: Bool = true) -> some View {
        if shows {
            overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
        } else {
            self
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

private enum AeonBuildIdentity {
    static let label: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "5.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        let manifest = Bundle.main.url(forResource: "Aeon-validation", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let commit = manifest.components(separatedBy: .newlines)
            .first { $0.hasPrefix("Commit: ") }.map { String($0.dropFirst(8).prefix(7)) }
        return "AEON \(version) · BUILD \(build)" + (commit.map { " · " + $0 } ?? " · LOCAL")
    }()
}
