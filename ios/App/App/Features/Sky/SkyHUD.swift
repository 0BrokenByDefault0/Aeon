import SwiftUI
import UIKit

struct SkyHUD: View {
    @ObservedObject var controller: SkySceneController
    let importProgress: LibraryImportProgress?
    let viewportSize: CGSize
    let showCensus: Bool
    let reduceMotionOverride: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var announcedTier: SkyZoomTier?
    var body: some View {
        VStack(spacing: 0) {
            topControls
            Spacer()
            if showCensus || importProgress != nil { censusStrip }
        }
        .onAppear { announcedTier = controller.camera.tier }
        .onChange(of: controller.camera.tier) { tier in
            guard announcedTier != tier else { return }
            announcedTier = tier
            UIAccessibility.post(notification: .announcement, argument: "Sky altitude, \(tier.rawValue)")
        }
    }
    private var topControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            AeonBreadcrumb(text: "Sky")
            if !controller.catalogue.stars.isEmpty {
                HStack(spacing: AeonTheme.Space.medium) {
                    Text("\(controller.camera.tier.rawValue.uppercased()) VIEW")
                        .accessibilityLabel("Sky altitude, \(controller.camera.tier.rawValue)")
                        .accessibilityIdentifier("aeon.sky.altitude")
                    Spacer(minLength: 0)
                    Menu("SAVE VIEW") {
                        Button("Current framing") { controller.makeCapture(wide: false, viewport: viewportSize) }
                        Button("Wider framing") { controller.makeCapture(wide: true, viewport: viewportSize) }
                    }
                    .accessibilityIdentifier("aeon.sky.capture")
                    if controller.playingStarID != nil {
                        Button("LOCATE") {
                            controller.locatePlaying(reduceMotion: reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion)
                        }.accessibilityIdentifier("aeon.sky.locate-playing")
                    }
                    if let captureURL = controller.captureURL {
                        ShareLink(item: captureURL) { Text("SHARE") }.accessibilityIdentifier("aeon.sky.share-capture")
                    }
                }
                .font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.2)
                .foregroundStyle(AeonOrbit.secondary).frame(minHeight: AeonTheme.Space.minimumTarget)
            }
        }
    }
    private var censusStrip: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: AeonTheme.Space.medium) {
                Text(controller.censusText)
                Text(controller.planetProgressText)
                if let nowPlayingText = controller.nowPlayingText { Text(nowPlayingText).lineLimit(1) }
                Spacer(minLength: 0)
            }
            if let progress = importProgress {
                AeonProgressBar(value: fraction(progress)).frame(maxWidth: 220)
                Text(importLabel(progress).uppercased()).foregroundStyle(AeonOrbit.ink)
            }
        }
        .font(AeonTheme.FontToken.metric(.caption2)).tracking(0.6).foregroundStyle(AeonOrbit.secondary)
        .padding(.horizontal, AeonTheme.Space.medium).padding(.vertical, AeonTheme.Space.small)
        .background(AeonTheme.ColorToken.void.opacity(0.62))
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
        .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("aeon.sky.hud")
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
