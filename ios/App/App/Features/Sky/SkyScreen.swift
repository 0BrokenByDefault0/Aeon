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
                            VStack {
                                Spacer()
                                emptyState
                                    .padding(.horizontal, edge)
                                    .padding(.bottom, readableInsets.bottom + AeonTheme.Space.large)
                            }
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
                        selectionFocus(viewport: geometry.size)
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
        VStack(spacing: AeonTheme.Space.small) {
            Text("Your sky is empty")
                .font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                .foregroundStyle(AeonOrbit.title)
            Text("Add music to begin charting it.")
                .font(AeonTheme.FontToken.ui(.caption))
                .foregroundStyle(AeonOrbit.secondary)
            Button("IMPORT MUSIC") { importSheetPresented = true }
                .buttonStyle(AeonButtonStyle(tier: .hairline))
                .fixedSize()
                .accessibilityIdentifier("aeon.library.import")
            if let importError, !importError.isEmpty {
                HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                    AeonGlyph(kind: .refresh).accessibilityHidden(true)
                    Text(importError).font(AeonTheme.FontToken.ui(.caption)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(AeonOrbit.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                .accessibilityIdentifier("aeon.sky.import.error")
            }
        }
        .padding(.horizontal, AeonTheme.Space.large)
        .padding(.vertical, AeonTheme.Space.medium)
        .background(AeonTheme.ColorToken.void.opacity(0.42), in: RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.empty")
    }
    private var effectiveReduceMotion: Bool { reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion }

    @ViewBuilder private func selectionFocus(viewport: CGSize) -> some View {
        if let planet = controller.selectedPlanet {
            planetMarker(planet, viewport: viewport)
        } else if let star = controller.selectedStar, let readout = controller.selectedAlbumReadout {
            marker(
                at: controller.camera.screenPoint(for: star.coordinate, viewport: SkyViewport(size: viewport)),
                title: readout.title,
                subtitle: readout.subtitle,
                viewport: viewport,
                identifier: "aeon.sky.star-selection"
            )
        } else if let center = controller.selectedConstellationCenter,
                  let readout = controller.selectedConstellationReadout {
            marker(
                at: controller.camera.screenPoint(for: center, viewport: SkyViewport(size: viewport)),
                title: readout.title,
                subtitle: readout.subtitle,
                viewport: viewport,
                identifier: "aeon.sky.constellation-selection"
            )
        }
    }

    private func planetMarker(_ planet: SkyPlanet, viewport: CGSize) -> some View {
        let point = controller.camera.screenPoint(for: planet.coordinate, viewport: SkyViewport(size: viewport))
        let readout = controller.selectedPlanetReadout
        return ZStack {
            VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                AeonDisplayText(readout?.title ?? planet.systemName, size: 22, maximumLines: 2)
                    .foregroundStyle(AeonTheme.ColorToken.primary)
                Text(readout?.subtitle ?? "\(planet.members.count) records")
                    .font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.secondary)
                HStack(spacing: AeonTheme.Space.medium) {
                    Button("EXPLORE SYSTEM") { controller.exploreSelectedPlanet(reduceMotion: effectiveReduceMotion) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aeon.sky.planet.explore")
                    Button("COLLECTION") { controller.showGalaxy(reduceMotion: effectiveReduceMotion) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aeon.sky.planet.galaxy")
                }
                .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                .foregroundStyle(AeonOrbit.ink)
            }
            .padding(.horizontal, AeonTheme.Space.medium).padding(.vertical, AeonTheme.Space.medium)
            .frame(maxWidth: Self.readoutMaximumWidth, alignment: .leading)
            .background(AeonTheme.ColorToken.void.opacity(0.58), in: RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18)
            .position(focusReadoutPosition(for: point, viewport: viewport, height: 126))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.planet-selection")
    }

    private func marker(at point: CGPoint, title: String, subtitle: String, viewport: CGSize, identifier: String) -> some View {
        ZStack {
            if controller.camera.tier != .focus {
                AeonReticleMark()
                    .stroke(AeonTheme.ColorToken.primary.opacity(0.42), lineWidth: AeonTheme.Stroke.hairline)
                    .frame(width: 30, height: 30)
                    .position(point)
            }
            VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                AeonDisplayText(title, size: 26, maximumLines: 2)
                    .foregroundStyle(AeonTheme.ColorToken.primary)
                Text(subtitle)
                    .font(AeonTheme.FontToken.secondary)
                    .foregroundStyle(AeonTheme.ColorToken.secondary)
            }
            .padding(.horizontal, AeonTheme.Space.small).padding(.vertical, AeonTheme.Space.xSmall)
            .frame(maxWidth: Self.readoutMaximumWidth, alignment: .leading)
            .background(AeonTheme.ColorToken.void.opacity(0.38), in: RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 16)
            .position(focusReadoutPosition(for: point, viewport: viewport, height: 76))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .allowsHitTesting(false)
    }

    private func focusReadoutPosition(for point: CGPoint, viewport: CGSize, height: CGFloat) -> CGPoint {
        let halfWidth = Self.readoutMaximumWidth / 2
        let x = min(viewport.width - halfWidth - 12, max(halfWidth + 12, point.x))
        let preferredY = point.y < viewport.height * 0.52 ? point.y + height : point.y - height
        let minimumY = readableInsets.top + 112
        let maximumY = viewport.height - readableInsets.bottom - 112
        return CGPoint(x: x, y: min(maximumY, max(minimumY, preferredY)))
    }

    private static let readoutMaximumWidth: CGFloat = 280
}

private struct SkyLabelOverlay: View {
    @ObservedObject var controller: SkySceneController
    let viewport: CGSize
    let highContrast: Bool
    var body: some View {
        ZStack {
            ForEach(labels) { label in
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
    private var labels: [SkyLabelLayout.Placed] {
        let camera = controller.camera
        let resolvedViewport = SkyViewport(size: viewport)
        let starByID = Dictionary(uniqueKeysWithValues: controller.catalogue.stars.map { ($0.albumID, $0) })
        let candidates: [SkyLabelLayout.Candidate]
        if camera.tier == .collection {
            let regions = controller.catalogue.regions.compactMap { region -> SkyLabelLayout.Candidate? in
                let points = controller.catalogue.stars.filter { $0.regionID == region.id }.map(\.coordinate)
                guard !points.isEmpty else { return nil }
                let center = SkyPoint(x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                                      y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count)))
                return SkyLabelLayout.Candidate(
                    id: region.id, text: region.name.uppercased(),
                    anchor: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: true
                )
            }
            let planets = controller.catalogue.planets.map { planet in
                SkyLabelLayout.Candidate(
                    id: planet.id, text: planet.name.uppercased(),
                    anchor: camera.screenPoint(for: planet.coordinate, viewport: resolvedViewport), isRegion: true
                )
            }
            candidates = planets + Array(regions.prefix(4))
        } else if camera.tier == .system || camera.tier == .album {
            let constellations = controller.catalogue.constellations.compactMap { constellation -> SkyLabelLayout.Candidate? in
                let points = constellation.albumIDs.compactMap { starByID[$0]?.coordinate }
                guard !points.isEmpty else { return nil }
                let center = SkyPoint(x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                                      y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count)))
                return SkyLabelLayout.Candidate(
                    id: constellation.id, text: constellation.artistName.uppercased(),
                    anchor: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: false
                )
            }
            let planets = controller.catalogue.planets.map { planet in
                SkyLabelLayout.Candidate(
                    id: planet.id, text: planet.name.uppercased(),
                    anchor: camera.screenPoint(for: planet.coordinate, viewport: resolvedViewport), isRegion: true
                )
            }
            candidates = planets + Array(constellations.prefix(camera.tier == .system ? 14 : 28))
        } else {
            candidates = []
        }
        return SkyLabelLayout.place(Array(candidates.prefix(80)), viewport: viewport)
    }
}

enum SkyLabelLayout {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let text: String
        let anchor: CGPoint
        let isRegion: Bool
    }

    struct Placed: Identifiable, Equatable {
        let id: String
        let text: String
        let position: CGPoint
        let frame: CGRect
        let isRegion: Bool
    }

    static func place(_ candidates: [Candidate], viewport: CGSize) -> [Placed] {
        let bounds = CGRect(x: 8, y: 176, width: max(0, viewport.width - 16), height: max(0, viewport.height - 272))
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var occupied: [CGRect] = []
        var placed: [Placed] = []
        for candidate in candidates.sorted(by: { $0.isRegion && !$1.isRegion }) {
            let width = min(candidate.isRegion ? 190 : 154, max(54, CGFloat(candidate.text.count) * (candidate.isRegion ? 8 : 6.4)))
            let size = CGSize(width: width, height: candidate.isRegion ? 28 : 22)
            let distance: CGFloat = candidate.isRegion ? 34 : 26
            let offsets = [
                CGPoint(x: 0, y: distance), CGPoint(x: 0, y: -distance),
                CGPoint(x: width / 2 + 18, y: 0), CGPoint(x: -width / 2 - 18, y: 0)
            ]
            guard let frame = offsets.lazy.map({ offset in
                CGRect(
                    x: candidate.anchor.x + offset.x - size.width / 2,
                    y: candidate.anchor.y + offset.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            }).first(where: { frame in
                bounds.contains(frame) && !occupied.contains(where: { $0.insetBy(dx: -8, dy: -6).intersects(frame) })
            }) else { continue }
            occupied.append(frame)
            placed.append(Placed(
                id: candidate.id, text: candidate.text,
                position: CGPoint(x: frame.midX, y: frame.midY), frame: frame, isRegion: candidate.isRegion
            ))
        }
        return placed
    }
}
