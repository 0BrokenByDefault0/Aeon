import SwiftUI

struct SkyHUD: View {
    @ObservedObject var controller: SkySceneController
    let importProgress: LibraryImportProgress?
    let viewportSize: CGSize
    let showCensus: Bool
    let reduceMotionOverride: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(controller.camera.tier.rawValue.uppercased())
                    .accessibilityLabel("Sky altitude, \(controller.camera.tier.rawValue)")
                    .accessibilityIdentifier("aeon.sky.altitude")
                Rectangle().fill(.white.opacity(0.28)).frame(width: 28, height: 1)
                Menu("CAPTURE") {
                    Button("Current framing") { controller.makeCapture(wide: false, viewport: viewportSize) }
                    Button("Wider framing") { controller.makeCapture(wide: true, viewport: viewportSize) }
                }
                .accessibilityIdentifier("aeon.sky.capture")
                if controller.playingStarID != nil {
                    Button("LOCATE") { controller.locatePlaying(reduceMotion: reduceMotion || reduceMotionOverride) }
                        .accessibilityIdentifier("aeon.sky.locate-playing")
                }
                if let captureURL = controller.captureURL {
                    ShareLink(item: captureURL) { Text("SHARE PLATE") }
                        .accessibilityIdentifier("aeon.sky.share-capture")
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.7)
            .foregroundStyle(.white.opacity(0.84))
            .frame(minHeight: 44)

            Spacer()

            if showCensus || importProgress != nil {
                HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.censusText)
                    Text(controller.planetProgressText)
                    if let nowPlayingText = controller.nowPlayingText { Text(nowPlayingText) }
                    if let progress = importProgress {
                        ProgressView(value: fraction(progress))
                            .tint(.white)
                            .frame(width: 180)
                        Text(importLabel(progress))
                    }
                }
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .padding(12)
                .background(Color.black.opacity(0.62))
                .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("aeon.sky.hud")
                Spacer()
                }
            }
        }
    }

    private func fraction(_ progress: LibraryImportProgress) -> Double {
        if progress.totalGroups > 0 { return Double(progress.completedGroups) / Double(progress.totalGroups) }
        guard progress.totalFiles > 0 else { return 0 }
        return Double(progress.completedFiles) / Double(progress.totalFiles)
    }

    private func importLabel(_ progress: LibraryImportProgress) -> String {
        switch progress.phase {
        case .scanning: return "charting source"
        case .readingMetadata: return "reading \(progress.completedFiles) of \(progress.totalFiles)"
        case .grouping: return "finding albums"
        case .committing: return "placing \(progress.completedGroups) of \(progress.totalGroups)"
        case .complete: return "the sky is current"
        }
    }
}
