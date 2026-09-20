import SwiftUI

struct SkyScreen: View {
    @ObservedObject var controller: SkySceneController
    let importProgress: LibraryImportProgress?
    let importError: String?
    let readableInsets: AeonReadableInsets
    let showHUD: Bool
    let highContrast: Bool
    let reduceMotionOverride: Bool
    let importFiles: () -> Void
    let adoptLibrary: () -> Void
    let commitSelection: (String) -> Void
    var isForeground = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importSheetPresented = false

    var body: some View {
        GeometryReader { geometry in
            let edge = geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge
            ZStack {
                SkyMetalView(controller: controller,
                             reduceMotionOverride: effectiveReduceMotion || !isForeground,
                             commitSelection: commitSelection,
                             isForeground: isForeground)
                    .ignoresSafeArea().opacity(controller.cameraCrossfade ? 0.28 : 1)
                    .animation(.linear(duration: 0.12), value: controller.cameraCrossfade)
                    .allowsHitTesting(isForeground)
                // Keep the renderer and camera alive, not the inactive screen's copy and controls.
                Group {
                    if isForeground {
                        SkyLabelOverlay(controller: controller, viewport: geometry.size, highContrast: highContrast)
                            .allowsHitTesting(false).accessibilityHidden(true)
                        // The only VoiceOver route into the sky. Without it every star,
                        // constellation and region is invisible to assistive technology.
                        SkyAccessibilityOverlay(controller: controller).allowsHitTesting(false)
                        SkyHUD(controller: controller, importProgress: importProgress, viewportSize: geometry.size,
                               showCensus: showHUD, reduceMotionOverride: reduceMotionOverride)
                            .padding(.horizontal, edge)
                            .padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))
                            .padding(.bottom, max(AeonTheme.Space.small, readableInsets.bottom))
                        if controller.catalogue.stars.isEmpty {
                            AeonQuietSkyBearings()
                            ScrollView {
                                emptyState
                                    .frame(minHeight: max(0, geometry.size.height - readableInsets.bottom - 88))
                                    .padding(.horizontal, edge)
                                    .padding(.top, 64).padding(.bottom, readableInsets.bottom + 24)
                            }
                            .scrollIndicators(.hidden)
                        }
                        if let ceremony = controller.ceremony {
                            VStack(spacing: AeonTheme.Space.xSmall) {
                                AeonLabel(text: "Celestial event")
                                AeonDisplayText(ceremony, size: 28, maximumLines: 2)
                            }
                            .foregroundStyle(AeonOrbit.title)
                            .padding(.horizontal, AeonTheme.Space.large).padding(.vertical, AeonTheme.Space.regular)
                            .background(AeonTheme.ColorToken.void.opacity(0.92))
                            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
                            .transition(.opacity).allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
                        }
                        selectionLabel(viewport: geometry.size)
                    }
                }
                .transaction { $0.animation = nil }
            }
            .background(AeonTheme.ColorToken.void)
        }
        .sheet(isPresented: $importSheetPresented) {
            AeonImportSheet(selectFiles: importFiles, adoptLibrary: adoptLibrary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AeonTheme.Space.large) {
            AeonEmptyState(title: "Your sky is quiet",
                           detail: "Bring your records. Aeon will chart them without changing the files you chose.",
                           actionTitle: "IMPORT MUSIC", motif: .sky,
                           actionIdentifier: "aeon.library.import") { importSheetPresented = true }
            if let importError, !importError.isEmpty {
                HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                    AeonGlyph(kind: .refresh).accessibilityHidden(true)
                    Text(importError).font(AeonTheme.FontToken.ui(.caption)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(AeonOrbit.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                .accessibilityIdentifier("aeon.sky.import.error")
            }
        }
        .frame(maxWidth: .infinity).accessibilityElement(children: .contain).accessibilityIdentifier("aeon.sky.empty")
    }
    private var effectiveReduceMotion: Bool { reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion }

    @ViewBuilder private func selectionLabel(viewport: CGSize) -> some View {
        if let planet = controller.selectedPlanet {
            marker(at: controller.camera.screenPoint(for: planet.coordinate, viewport: SkyViewport(size: viewport)),
                   viewport: viewport,
                   title: "WORLD \(planet.index)",
                   subtitle: "\(planet.members.count) ALBUMS")
                .accessibilityIdentifier("aeon.sky.planet-selection")
        } else if let star = controller.selectedStar {
            marker(at: controller.camera.screenPoint(for: star.coordinate, viewport: SkyViewport(size: viewport)),
                   viewport: viewport,
                   title: (controller.selectedAlbumTitle ?? star.albumID).uppercased(),
                   subtitle: star.artistName.uppercased())
                .accessibilityIdentifier("aeon.sky.star-selection")
        }
    }

    /// The marked star keeps its reticle; the readout is clamped into the viewport so a
    /// selection near an edge cannot slide under the status bar or off the screen.
    private func marker(at point: CGPoint, viewport: CGSize, title: String, subtitle: String) -> some View {
        let halfWidth = Self.readoutMaximumWidth / 2
        let clampedX = min(max(point.x, halfWidth + AeonTheme.Space.small), max(halfWidth + AeonTheme.Space.small, viewport.width - halfWidth - AeonTheme.Space.small))
        let above = point.y - Self.readoutOffset
        let clampedY = above < readableInsets.top + Self.readoutOffset
            ? point.y + Self.readoutOffset
            : above
        return ZStack {
            AeonReticleMark()
                .stroke(AeonTheme.ColorToken.primary.opacity(0.62), style: AeonOrbit.line)
                .frame(width: 46, height: 46)
                .position(point)
            VStack(spacing: 2) {
                Text(title).font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.1)
                    .foregroundStyle(AeonTheme.ColorToken.primary)
                Text(subtitle).font(AeonTheme.FontToken.metric(.caption2))
                    .foregroundStyle(AeonTheme.ColorToken.secondary)
            }
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, AeonTheme.Space.small).padding(.vertical, AeonTheme.Space.xSmall)
            .frame(maxWidth: Self.readoutMaximumWidth)
            .background(AeonTheme.ColorToken.void.opacity(0.88))
            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
            .position(x: clampedX, y: min(max(clampedY, readableInsets.top + 20), max(readableInsets.top + 20, viewport.height - readableInsets.bottom - 20)))
        }
        .allowsHitTesting(false)
    }

    private static let readoutMaximumWidth: CGFloat = 240
    private static let readoutOffset: CGFloat = 44
}

enum AeonQuietSkyMarkers {
    static let labels = ["UNCHARTED", "UNLIT"]
}

/// Two quiet edge readings for a sky with nothing charted in it yet.
///
/// The starfield itself is drawn by the renderer's fixed-seed backdrop, so this no
/// longer duplicates it in SwiftUI; all that remains is the pair of bearings that
/// give an otherwise featureless field a sense of scale.
struct AeonQuietSkyBearings: View {
    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(AeonQuietSkyMarkers.labels.enumerated()), id: \.offset) { index, name in
                Text(name).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2).foregroundStyle(AeonOrbit.ink.opacity(0.19))
                    .position(x: geometry.size.width * (index == 0 ? 0.16 : 0.83),
                              y: geometry.size.height * 0.23)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct SkyLabelOverlay: View {
    @ObservedObject var controller: SkySceneController
    let viewport: CGSize
    let highContrast: Bool
    var body: some View {
        ZStack {
            ForEach(labels.prefix(80)) { label in
                Text(label.text).font(.system(size: label.isRegion ? 13 : 10, weight: .medium, design: .monospaced))
                    .tracking(label.isRegion ? 1.6 : 0.8)
                    // 0.14 on pure black is below the threshold of legibility; region names
                    // were effectively invisible even with Sky contrast turned on, because
                    // the flag was never plumbed through from Settings.
                    .foregroundStyle(AeonTheme.ColorToken.primary.opacity(highContrast ? 1 : (label.isRegion ? 0.34 : 0.52)))
                    .position(label.position)
            }
        }
    }
    private var labels: [Label] {
        let camera = controller.camera
        let resolvedViewport = SkyViewport(size: viewport)
        let starByID = Dictionary(uniqueKeysWithValues: controller.catalogue.stars.map { ($0.albumID, $0) })
        if camera.tier == .galaxy {
            return controller.catalogue.regions.compactMap { region in
                let points = controller.catalogue.stars.filter { $0.regionID == region.id }.map(\.coordinate)
                guard !points.isEmpty else { return nil }
                let center = SkyPoint(x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                                      y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count)))
                return Label(id: region.id, text: region.name.uppercased(), position: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: true)
            }.filter(visible)
        }
        guard camera.tier == .region || camera.tier == .constellation else { return [] }
        return controller.catalogue.constellations.compactMap { constellation in
            let points = constellation.albumIDs.compactMap { starByID[$0]?.coordinate }
            guard !points.isEmpty else { return nil }
            let center = SkyPoint(x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                                  y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count)))
            return Label(id: constellation.id, text: constellation.artistName.uppercased(), position: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: false)
        }.filter(visible)
    }
    private func visible(_ label: Label) -> Bool {
        (-80...viewport.width + 80).contains(label.position.x) && (-80...viewport.height + 80).contains(label.position.y)
    }
    private struct Label: Identifiable {
        let id: String
        let text: String
        let position: CGPoint
        let isRegion: Bool
    }
}
