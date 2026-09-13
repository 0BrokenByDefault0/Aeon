import SwiftUI
import UniformTypeIdentifiers

struct AeonRootView: View {
    @ObservedObject var container: AppContainer
    @State private var isRestoringCatalog = false

    var body: some View {
        ZStack {
            if container.legacyBridgeRequired {
                LegacyMigrationControllerView(probe: container.legacyMigrationProbe)
                    .id(ObjectIdentifier(container.legacyMigrationProbe))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Color.black.ignoresSafeArea()
            content
                .padding(32)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("aeon.root")
        .fileImporter(
            isPresented: $isRestoringCatalog,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            container.restoreCatalog(from: url)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch container.launchState {
        case .launching:
            launchMessage("OPENING AEON")
        case .checkingLegacyLibrary:
            launchMessage("CHECKING LIBRARY")
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
            .accessibilityIdentifier("aeon.launch.migrating")
        case .ready:
            VStack(spacing: 12) {
                Text("AEON")
                    .font(.system(size: 42, weight: .light, design: .serif))
                    .tracking(5)
                Text("NATIVE CORE READY")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .accessibilityIdentifier("aeon.launch.ready")
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
                        Button("Restore Catalogue") { isRestoringCatalog = true }
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
}

private struct LegacyMigrationControllerView: UIViewControllerRepresentable {
    let probe: LegacyMigrationInventoryProbe

    func makeUIViewController(context: Context) -> LegacyMigrationViewController {
        LegacyMigrationViewController(inventoryProbe: probe)
    }

    func updateUIViewController(_ controller: LegacyMigrationViewController, context: Context) {}
}
