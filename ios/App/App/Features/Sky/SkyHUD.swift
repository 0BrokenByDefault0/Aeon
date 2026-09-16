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
            if showCensus || importProgress != nil {
                censusStrip
            }
        }
        .onAppear { announcedTier = controller.camera.tier }
        .onChange(of: controller.camera.tier) { tier in
            guard announcedTier != tier else { return }
            announcedTier = tier
            UIAccessibility.post(notification: .announcement, argument: "Sky altitude, \(tier.rawValue)")
        }
    }

    private var topControls: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            // The altitude word changes as the sky is moved, and everything
            // after it used to slide as the word got longer or shorter. The
            // hidden names hold the slot at the width of the longest one, so
            // the controls beside it stay put.
            ZStack(alignment: .leading) {
                ForEach(SkyZoomTier.allCases, id: \.self) { tier in
                    Text(tier.rawValue.uppercased()).hidden()
                }
                Text(controller.camera.tier.rawValue.uppercased())
            }
            .accessibilityLabel("Sky altitude, \(controller.camera.tier.rawValue)")
            .accessibilityIdentifier("aeon.sky.altitude")
            Rectangle()
                .fill(AeonTheme.ColorToken.ivorySecondary.opacity(0.48))
                .frame(width: 28, height: AeonTheme.Stroke.hairline)
            Menu("CAPTURE") {
                Button("Current framing") { controller.makeCapture(wide: false, viewport: viewportSize) }
                Button("Wider framing") { controller.makeCapture(wide: true, viewport: viewportSize) }
            }
            .accessibilityIdentifier("aeon.sky.capture")
            if controller.playingStarID != nil {
                Button("LOCATE") {
                    controller.locatePlaying(
                        reduceMotion: reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion
                    )
                }
                .accessibilityIdentifier("aeon.sky.locate-playing")
            }
            if let captureURL = controller.captureURL {
                ShareLink(item: captureURL) { Text("SHARE") }
                    .accessibilityIdentifier("aeon.sky.share-capture")
            }
            Spacer()
        }
        .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
        .tracking(1.6)
        .foregroundStyle(AeonTheme.ColorToken.ivorySecondary)
        .frame(minHeight: AeonTheme.Space.minimumTarget)
    }

    private var censusStrip: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: AeonTheme.Space.medium) {
                Text(controller.censusText)
                Text(controller.planetProgressText)
                if let nowPlayingText = controller.nowPlayingText {
                    Text(nowPlayingText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let progress = importProgress {
                AeonProgressBar(value: fraction(progress))
                    .frame(maxWidth: 220)
                Text(importLabel(progress).uppercased())
                    .foregroundStyle(AeonTheme.ColorToken.bone)
            }
        }
        .font(AeonTheme.FontToken.metric(.caption2))
        .tracking(0.6)
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        .padding(.horizontal, AeonTheme.Space.medium)
        .padding(.vertical, AeonTheme.Space.small)
        .background(
            RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                .fill(AeonTheme.ColorToken.void.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("aeon.sky.hud")
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
