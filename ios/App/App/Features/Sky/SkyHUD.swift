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
        HStack(spacing: AeonTheme.Space.small) {
            Text("SKY")
                .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(AeonOrbit.ink.opacity(0.78))
                .accessibilityLabel("Sky, \(controller.viewModeLabel)")
                .accessibilityIdentifier("aeon.sky.altitude")
            Spacer(minLength: 0)
            if !controller.catalogue.stars.isEmpty {
                if controller.camera.selectedID != nil || controller.camera.tier != .collection {
                    Button {
                        controller.showGalaxy(reduceMotion: reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion)
                    } label: { hudAction(glyph: .sky) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Return to collection")
                    .accessibilityIdentifier("aeon.sky.galaxy")
                }
                if controller.playingStarID != nil {
                    Button {
                        controller.locatePlaying(reduceMotion: reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion)
                    } label: { hudAction(glyph: .star) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Locate playing album")
                    .accessibilityIdentifier("aeon.sky.locate-playing")
                }
                Menu {
                    Button("CAPTURE CURRENT VIEW") { controller.makeCapture(wide: false, viewport: viewportSize) }
                    Button("CAPTURE WIDE VIEW") { controller.makeCapture(wide: true, viewport: viewportSize) }
                    if let captureURL = controller.captureURL {
                        ShareLink(item: captureURL) { Text("SHARE LAST CAPTURE") }
                    }
                } label: { hudAction(glyph: .more) }
                    .accessibilityLabel("Sky utilities")
                    .accessibilityIdentifier("aeon.sky.capture")
            }
        }
        .foregroundStyle(AeonOrbit.secondary)
        .frame(minHeight: AeonTheme.Space.minimumTarget)
    }

    private func hudAction(glyph: AeonGlyphKind) -> some View {
        AeonGlyph(kind: glyph)
            .frame(width: 18, height: 18)
            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            .background(AeonTheme.ColorToken.void.opacity(0.34), in: Circle())
        .contentShape(Rectangle())
    }
    private var censusStrip: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            if showCensus {
                HStack(alignment: .firstTextBaseline, spacing: AeonTheme.Space.medium) {
                    Text(controller.censusText)
                    if let nowPlayingText = controller.nowPlayingText { Text(nowPlayingText).lineLimit(1) }
                    Spacer(minLength: 0)
                }
            }
            if let progress = importProgress {
                AeonProgressBar(value: fraction(progress)).frame(maxWidth: 220)
                Text(importLabel(progress).uppercased()).foregroundStyle(AeonOrbit.ink)
            }
        }
        .font(AeonTheme.FontToken.metric(.caption2)).tracking(0.6).foregroundStyle(AeonOrbit.secondary.opacity(0.78))
        .padding(.horizontal, AeonTheme.Space.small).padding(.vertical, AeonTheme.Space.xSmall)
        .background(AeonTheme.ColorToken.void.opacity(0.32), in: RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous))
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
