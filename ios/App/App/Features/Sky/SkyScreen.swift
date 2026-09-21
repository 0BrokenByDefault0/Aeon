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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var importSheetPresented = false

    var body: some View {
        GeometryReader { geometry in
            let edge = geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge
            ZStack {
                SkyMetalView(controller: controller,
                             reduceMotionOverride: effectiveReduceMotion || !isForeground,
                             commitSelection: commitSelection,
                             isForeground: isForeground,
                             usableSize: CGSize(width: geometry.size.width,
                                height: max(1, geometry.size.height - readableInsets.top - 44 - readableInsets.bottom - accessibilityReserve)))
                    .opacity(controller.cameraCrossfade ? 0.28 : 1)
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
                            // The full-bleed geometry has no safe inset; use the root's measurement.
                            .padding(.top, max(AeonTheme.Space.small, readableInsets.top))
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
            .onAppear {
                controller.updateViewport(geometry.size)
                controller.updateFocusInsets(top: readableInsets.top + 44, bottom: readableInsets.bottom + accessibilityReserve)
            }
            .onChange(of: readableInsets) { insets in
                controller.updateFocusInsets(top: insets.top + 44, bottom: insets.bottom + accessibilityReserve)
            }
            .onChange(of: geometry.size) { controller.updateViewport($0) }
            .onChange(of: dynamicTypeSize) { _ in
                controller.updateFocusInsets(top: readableInsets.top + 44, bottom: readableInsets.bottom + accessibilityReserve)
            }
        }
        .ignoresSafeArea(.container)
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
                .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                .tracking(1.4)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .foregroundStyle(AeonOrbit.ink)
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
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.empty")
    }

    private var accessibilityReserve: CGFloat { dynamicTypeSize.isAccessibilitySize ? 100 : 0 }
    private var effectiveReduceMotion: Bool { reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion }

    @ViewBuilder private func selectionFocus(viewport: CGSize) -> some View {
        if let planet = controller.selectedPlanet {
            planetMarker(planet, viewport: viewport)
        }
    }

    private func planetMarker(_ planet: SkyPlanet, viewport: CGSize) -> some View {
        let point = controller.camera.screenPoint(for: planet.coordinate, viewport: SkyViewport(size: viewport))
        let readout = controller.selectedPlanetReadout
        return ZStack {
            VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                AeonDisplayText(readout?.title ?? planet.name, size: 26, maximumLines: 2)
                    .foregroundStyle(AeonTheme.ColorToken.primary)
                Text(readout?.subtitle ?? "\(planet.members.count) records")
                    .font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.secondary)
                HStack(spacing: AeonTheme.Space.medium) {
                    Button("CLOSE") { controller.select(nil) }
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close planet details")
                        .accessibilityIdentifier("aeon.sky.planet.close")
                    Button("COLLECTION") { controller.showGalaxy(reduceMotion: effectiveReduceMotion) }
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aeon.sky.planet.galaxy")
                }
                .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                .foregroundStyle(AeonOrbit.ink)
            }
            .padding(.horizontal, AeonTheme.Space.medium).padding(.vertical, AeonTheme.Space.medium)
            .frame(maxWidth: Self.readoutMaximumWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.45), radius: 18)
            .position(focusReadoutPosition(for: point, viewport: viewport,
                                          height: controller.planetBodyRadius(planet) * CGFloat(planet.resolvedMaterial.ringExtent) + 68))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.planet-selection")
    }

    private func focusReadoutPosition(for point: CGPoint, viewport: CGSize, height: CGFloat) -> CGPoint {
        let halfWidth = Self.readoutMaximumWidth / 2
        let x = min(viewport.width - halfWidth - 12, max(halfWidth + 12, point.x))
        let preferredY = controller.selectedConstellation == nil ? point.y + height : point.y - height
        let minimumY = readableInsets.top + 112
        let maximumY = viewport.height - readableInsets.bottom - 70
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
                Text(label.text).font(.system(size: label.isRegion ? 12 : 12, weight: .medium, design: label.isRegion ? .monospaced : .default))
                    .lineLimit(1).frame(width: label.frame.width, height: label.frame.height)
                    .tracking(label.isRegion ? 1.4 : 0.1)
                    .opacity(label.opacity)
                    // 0.14 on pure black is below the threshold of legibility; region names
                    // were effectively invisible even with Sky contrast turned on, because
                    // the flag was never plumbed through from Settings.
                    .foregroundStyle(AeonTheme.ColorToken.primary.opacity(highContrast ? 1 : (label.isRegion ? 0.62 : 0.84)))
                    .position(label.position)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: labels.map(\.id))
    }
    private var labels: [SkyLabelLayout.Placed] {
        let camera = controller.camera
        let resolvedViewport = SkyViewport(size: viewport)
        let starByID = Dictionary(uniqueKeysWithValues: controller.catalogue.stars.map { ($0.albumID, $0) })
        var candidates: [SkyLabelLayout.Candidate] = []
        var obstacles: [CGRect] = []
        for planet in controller.catalogue.planets {
            let point = camera.screenPoint(for: planet.coordinate, viewport: resolvedViewport)
            let radius = controller.planetBodyRadius(planet) * CGFloat(planet.resolvedMaterial.ringExtent)
            obstacles.append(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        // Selection never overrides distance disclosure. In particular a selected album
        // must not pin a large title card or suppress artist/genre names on zoom-out.
        let disclosure = SkyDisclosure(scale: camera.scale)
        if disclosure.region > 0 {
            for region in controller.catalogue.regions {
                let points = controller.catalogue.stars.filter { $0.regionID == region.id }.map(\.coordinate)
                guard !points.isEmpty else { continue }
                let center = SkyPoint(x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                                      y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count)))
                candidates.append(.init(id: "region-" + region.id, text: region.name.uppercased(),
                    anchor: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: true, opacity: disclosure.region))
            }
        }
        if disclosure.artist > 0 {
            for artist in controller.catalogue.constellations {
                let members = artist.albumIDs.compactMap { starByID[$0]?.coordinate }
                guard !members.isEmpty else { continue }
                let center = SkyPoint(x: Int32(members.map { Int64($0.x) }.reduce(0, +) / Int64(members.count)),
                                      y: Int32(members.map { Int64($0.y) }.reduce(0, +) / Int64(members.count)))
                candidates.append(.init(id: "artist-" + artist.id, text: artist.artistName,
                    anchor: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: false, opacity: disclosure.artist))
            }
        }
        if disclosure.album > 0 {
            for star in controller.catalogue.stars {
                candidates.append(.init(id: "album-" + star.id, text: star.title ?? star.albumID,
                    anchor: camera.screenPoint(for: star.coordinate, viewport: resolvedViewport), isRegion: false, opacity: disclosure.album))
            }
        }
        for star in controller.catalogue.stars {
            let point = camera.screenPoint(for: star.coordinate, viewport: resolvedViewport)
            obstacles.append(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
        }
        let visible = candidates.filter { CGRect(origin: .zero, size: viewport).contains($0.anchor) }
            .sorted {
                if $0.opacity != $1.opacity { return $0.opacity > $1.opacity }
                let left = hypot($0.anchor.x - viewport.width / 2, $0.anchor.y - viewport.height / 2)
                let right = hypot($1.anchor.x - viewport.width / 2, $1.anchor.y - viewport.height / 2)
                return left == right ? $0.id < $1.id : left < right
            }
        return SkyLabelLayout.place(Array(visible.prefix(camera.scale < 0.65 ? 5 : 10)), viewport: viewport,
                                    obstacles: obstacles, usableBounds: controller.usableSkyBounds)
    }
}

struct SkyDisclosure {
    let region: Double
    let artist: Double
    let album: Double
    init(scale: Double) {
        func fade(_ low: Double, _ high: Double) -> Double {
            let t = min(1, max(0, (scale - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        // Retain the approved 0.65 and 1.6 centers; crossfade around them.
        region = 1 - fade(0.57, 0.73)
        album = fade(1.44, 1.76)
        artist = (1 - region) * (1 - album)
    }
}

enum SkyLabelLayout {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let text: String
        let anchor: CGPoint
        let isRegion: Bool
        var opacity: Double = 1
    }

    struct Placed: Identifiable, Equatable {
        let id: String
        let text: String
        let position: CGPoint
        let frame: CGRect
        let isRegion: Bool
        var opacity: Double = 1
    }

    static func place(_ candidates: [Candidate], viewport: CGSize, obstacles: [CGRect] = [], usableBounds: CGRect? = nil) -> [Placed] {
        let bounds = (usableBounds ?? CGRect(origin: .zero, size: viewport)).insetBy(dx: 8, dy: 8)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var occupied: [CGRect] = obstacles
        var placed: [Placed] = []
        for candidate in candidates {
            let width = min(220, max(54, CGFloat(candidate.text.count) * (candidate.isRegion ? 9.2 : 7.5) + 8))
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
                position: CGPoint(x: frame.midX, y: frame.midY), frame: frame, isRegion: candidate.isRegion, opacity: candidate.opacity
            ))
        }
        return placed
    }
}
