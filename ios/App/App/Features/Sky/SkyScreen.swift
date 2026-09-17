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
    let importFolder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importSheetPresented = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SkyMetalView(controller: controller, reduceMotionOverride: reduceMotionOverride)
                    .ignoresSafeArea().opacity(controller.cameraCrossfade ? 0.28 : 1)
                    .animation(.linear(duration: 0.12), value: controller.cameraCrossfade)
                if controller.catalogue.stars.isEmpty {
                    AeonQuietSky(reduceMotion: effectiveReduceMotion,
                                 regions: controller.catalogue.regions.map { $0.name.uppercased() })
                        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
                }
                SkyLabelOverlay(controller: controller, viewport: geometry.size, highContrast: highContrast)
                    .allowsHitTesting(false).accessibilityHidden(true)
                SkyAccessibilityOverlay(controller: controller).allowsHitTesting(false)
                SkyHUD(controller: controller, importProgress: importProgress, viewportSize: geometry.size,
                       showCensus: showHUD, reduceMotionOverride: reduceMotionOverride)
                    .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
                    .padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))
                    .padding(.bottom, max(AeonTheme.Space.small, readableInsets.bottom))
                if controller.catalogue.stars.isEmpty {
                    ScrollView {
                        emptyState
                            .frame(minHeight: max(0, geometry.size.height - readableInsets.bottom - 88))
                            .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
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
                selectionLabel
            }
            .background(AeonTheme.ColorToken.void)
        }
        .sheet(isPresented: $importSheetPresented) {
            AeonImportSheet(selectFiles: importFiles, selectFolder: importFolder)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AeonTheme.Space.large) {
            AeonGhostDisc().frame(width: 142, height: 142).padding(.bottom, AeonTheme.Space.small)
            VStack(spacing: AeonTheme.Space.regular) {
                AeonDisplayText("Your sky is quiet", size: 38, maximumLines: 2)
                    .foregroundStyle(AeonOrbit.title).multilineTextAlignment(.center)
                Text("Bring your records. Aeon will chart them without changing the files you chose.")
                    .font(AeonTheme.FontToken.ui(.callout)).foregroundStyle(AeonOrbit.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }
            Button("IMPORT MUSIC") { importSheetPresented = true }
                .buttonStyle(AeonButtonStyle(tier: .filled)).frame(maxWidth: 286)
                .padding(.top, AeonTheme.Space.small).accessibilityIdentifier("aeon.library.import")
            if let importError, !importError.isEmpty {
                HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text(importError).font(AeonTheme.FontToken.ui(.caption)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(AeonOrbit.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                .accessibilityIdentifier("aeon.sky.import.error")
            }
        }
        .frame(maxWidth: .infinity).accessibilityElement(children: .contain).accessibilityIdentifier("aeon.sky.empty")
    }
    private var effectiveReduceMotion: Bool { reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion }

    @ViewBuilder private var selectionLabel: some View {
        if let planet = controller.selectedPlanet {
            VStack {
                Spacer()
                selectionReadout("WORLD \(planet.index) · \(planet.members.count) ALBUMS")
                    .accessibilityIdentifier("aeon.sky.planet-selection")
            }.padding(.bottom, readableInsets.bottom + 24)
        } else if let star = controller.selectedStar {
            VStack {
                Spacer()
                selectionReadout("\(star.artistName.uppercased()) · ALBUM \(star.sequence)")
                    .accessibilityIdentifier("aeon.sky.star-selection")
            }.padding(.bottom, readableInsets.bottom + 24)
        }
    }
    private func selectionReadout(_ text: String) -> some View {
        Text(text).font(AeonTheme.FontToken.metric(.caption, weight: .medium)).tracking(1.4)
            .foregroundStyle(AeonOrbit.ink).padding(.horizontal, AeonTheme.Space.regular)
            .frame(minHeight: AeonTheme.Space.minimumTarget)
            .background(AeonTheme.ColorToken.void.opacity(0.88))
            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
    }
}

/// Decorative sky only; these points never enter the catalogue or hit-testing model.
private struct AeonQuietSky: View {
    let reduceMotion: Bool
    let regions: [String]
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
                    let names = regions.isEmpty ? ["UNCHARTED", "UNLIT", "UNCHARTED", "UNLIT"] : regions
                    ForEach(0..<min(4, names.count), id: \.self) { index in
                        Text(names[index]).font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(2).foregroundStyle(AeonOrbit.ink.opacity(0.19))
                            .position(x: geometry.size.width * (index.isMultiple(of: 2) ? 0.16 : 0.83),
                                      y: geometry.size.height * (index < 2 ? 0.23 : 0.76))
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
                Text(label.text).font(.system(size: label.isRegion ? 12 : 10, weight: .medium, design: .monospaced))
                    .tracking(label.isRegion ? 1.6 : 0.8)
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary.opacity(highContrast ? 1 : (label.isRegion ? 0.9 : 0.82)))
                    .shadow(color: .black, radius: 3).position(label.position)
            }
        }
    }
    private var labels: [Label] {
        let camera = controller.camera
        let resolvedViewport = SkyViewport(size: viewport)
        let starByID = Dictionary(uniqueKeysWithValues: controller.catalogue.stars.map { ($0.albumID, $0) })
        if camera.tier == .galaxy || camera.tier == .region {
            return controller.catalogue.regions.compactMap { region in
                let points = controller.catalogue.stars.filter { $0.regionID == region.id }.map(\.coordinate)
                guard !points.isEmpty else { return nil }
                let center = SkyPoint(x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                                      y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count)))
                return Label(id: region.id, text: region.name.uppercased(), position: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: true)
            }.filter(visible)
        }
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
