import SwiftUI

struct SkyScreen: View {
    @ObservedObject var controller: SkySceneController
    let readableInsets: AeonReadableInsets
    let reduceMotionOverride: Bool
    let importFiles: () -> Void
    let adoptLibrary: () -> Void
    let commitSelection: (String) -> Void
    var isForeground = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importSheetPresented = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SkyMetalView(controller: controller, reduceMotionOverride: reduceMotionOverride, commitSelection: commitSelection)
                    .ignoresSafeArea().opacity(controller.cameraCrossfade ? 0.28 : 1)
                    .animation(.linear(duration: 0.12), value: controller.cameraCrossfade)
                    .allowsHitTesting(isForeground)
                Group {
                    if isForeground {
                        SkyLabelOverlay(controller: controller, viewport: geometry.size, highContrast: false)
                            .allowsHitTesting(false).accessibilityHidden(true)
                        if controller.catalogue.stars.isEmpty {
                            emptyState.frame(maxWidth: 300)
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
            Text("Your sky is quiet")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(AeonTheme.ColorToken.secondary)
            Button("IMPORT MUSIC") { importSheetPresented = true }
                .buttonStyle(AeonButtonStyle(tier: .filled))
                .accessibilityIdentifier("aeon.library.import")
        }
        .frame(maxWidth: .infinity).accessibilityElement(children: .contain).accessibilityIdentifier("aeon.sky.empty")
    }
    private var effectiveReduceMotion: Bool { reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion }

    @ViewBuilder private func selectionLabel(viewport: CGSize) -> some View {
        if let star = controller.selectedStar {
            let point = controller.camera.screenPoint(for: star.coordinate, viewport: SkyViewport(size: viewport))
            VStack(spacing: 2) {
                Text((controller.selectedAlbumTitle ?? star.albumID).uppercased()).font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.1)
                Text(star.artistName).font(AeonTheme.FontToken.metric(.caption2)).foregroundStyle(AeonTheme.ColorToken.secondary.opacity(0.5))
            }
            .foregroundStyle(AeonTheme.ColorToken.primary)
            .position(x: point.x, y: point.y - 30)
            .overlay(Circle().stroke(AeonTheme.ColorToken.primary.opacity(0.45), lineWidth: 1).frame(width: 34, height: 34).position(point))
            .accessibilityIdentifier("aeon.sky.star-selection")
        }
    }
}

enum AeonQuietSkyMarkers {
    static let labels = ["UNCHARTED", "UNLIT"]
}

/// Decorative sky only; these points never enter the catalogue or hit-testing model.
private struct AeonQuietSky: View {
    let reduceMotion: Bool
    let showMarkers: Bool
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || scenePhase != .active)) { timeline in
            GeometryReader { geometry in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    AeonTheme.ColorToken.void
                    Canvas { context, size in
                        for index in 0..<84 {
                            let seed = Double(index + 1)
                            let x = (seed * 0.61803398875).truncatingRemainder(dividingBy: 1)
                            let y = (seed * 0.41421356237).truncatingRemainder(dividingBy: 1)
                            let depth = Double(index % 3 + 1)
                            let offsetX = reduceMotion ? 0 : sin(time * 0.065 + depth) * depth * 1.4
                            let offsetY = reduceMotion ? 0 : cos(time * 0.047 + depth) * depth
                            let radius = index % 11 == 0 ? 1.0 : 0.55
                            let twinkle = index == 23 && !reduceMotion ? sin(time * 0.55) * 0.08 : 0
                            let alpha = (index % 11 == 0 ? 0.26 : 0.11) + twinkle
                            let star = CGRect(x: x * size.width + offsetX, y: y * size.height + offsetY,
                                              width: radius * 2, height: radius * 2)
                            context.fill(Path(ellipseIn: star), with: .color(AeonOrbit.ink.opacity(alpha)))
                        }
                    }
                    if showMarkers {
                        // Two quiet edge readings, not four duplicate quadrant labels.
                        ForEach(Array(AeonQuietSkyMarkers.labels.enumerated()), id: \.offset) { index, name in
                            Text(name).font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(2).foregroundStyle(AeonOrbit.ink.opacity(0.19))
                                .position(x: geometry.size.width * (index == 0 ? 0.16 : 0.83),
                                          y: geometry.size.height * 0.23)
                        }
                    }
                }
            }
        }
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
                    .foregroundStyle(AeonTheme.ColorToken.primary.opacity(highContrast ? 1 : (label.isRegion ? 0.14 : 0.30)))
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
