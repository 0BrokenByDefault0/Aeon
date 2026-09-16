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
    @State private var constellationBreathing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SkyMetalView(controller: controller, reduceMotionOverride: reduceMotionOverride)
                    .ignoresSafeArea()
                    .opacity(controller.cameraCrossfade ? 0.28 : 1)
                    .animation(.linear(duration: 0.12), value: controller.cameraCrossfade)
                SkyLabelOverlay(controller: controller, viewport: geometry.size, highContrast: highContrast)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                SkyAccessibilityOverlay(controller: controller)
                    .allowsHitTesting(false)
                SkyHUD(
                    controller: controller,
                    importProgress: importProgress,
                    viewportSize: geometry.size,
                    showCensus: showHUD,
                    reduceMotionOverride: reduceMotionOverride
                )
                .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
                .padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))
                .padding(.bottom, max(AeonTheme.Space.small, readableInsets.bottom))

                if controller.catalogue.stars.isEmpty {
                    emptyState
                        .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
                        .padding(.bottom, max(20, readableInsets.bottom * 0.35))
                }

                if let ceremony = controller.ceremony {
                    VStack(spacing: AeonTheme.Space.xSmall) {
                        AeonLabel(text: "Celestial event")
                        AeonDisplayText(ceremony, size: AeonTheme.FontToken.Display.name, maximumLines: 2)
                    }
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    .padding(.horizontal, AeonTheme.Space.large)
                    .padding(.vertical, AeonTheme.Space.regular)
                    .background(
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous)
                            .fill(AeonTheme.ColorToken.chamber.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous)
                            .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                selectionLabel
            }
            .background(AeonTheme.ColorToken.void)
        }
        .sheet(isPresented: $importSheetPresented) {
            AeonImportSheet(selectFiles: importFiles, selectFolder: importFolder)
        }
        .onAppear { updateConstellationBreathing() }
        .onChange(of: reduceMotion) { _ in updateConstellationBreathing() }
        .onChange(of: reduceMotionOverride) { _ in updateConstellationBreathing() }
    }

    private var emptyState: some View {
        VStack(spacing: AeonTheme.Space.large) {
            AeonRouteMark(width: 154, height: 96)
                .scaleEffect(effectiveReduceMotion ? 1 : (constellationBreathing ? 1.035 : 0.99))
                .opacity(effectiveReduceMotion ? 0.88 : (constellationBreathing ? 0.96 : 0.72))

            VStack(spacing: AeonTheme.Space.small) {
                AeonDisplayText("A place for your records.", size: AeonTheme.FontToken.Display.hero, maximumLines: 2)
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Bring albums in and Aeon will chart them without changing the files you chose.")
                    .font(AeonTheme.FontToken.ui(.body))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button("IMPORT MUSIC") { importSheetPresented = true }
                .buttonStyle(AeonButtonStyle(tier: .filled))
                .frame(maxWidth: 260)
                .accessibilityIdentifier("aeon.library.import")

            if let importError, !importError.isEmpty {
                HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                    Text(importError)
                        .font(AeonTheme.FontToken.ui(.caption))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .accessibilityIdentifier("aeon.sky.import.error")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.empty")
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion
    }

    private func updateConstellationBreathing() {
        if effectiveReduceMotion {
            constellationBreathing = false
            return
        }
        constellationBreathing = false
        withAnimation(.easeInOut(duration: AeonTheme.Duration.constellationBreath).repeatForever(autoreverses: true)) {
            constellationBreathing = true
        }
    }

    @ViewBuilder
    private var selectionLabel: some View {
        if let planet = controller.selectedPlanet {
            VStack {
                Spacer()
                selectionPill("WORLD \(planet.index) · \(planet.members.count) ALBUMS")
                    .accessibilityIdentifier("aeon.sky.planet-selection")
            }
            .padding(.bottom, 24)
        } else if let star = controller.selectedStar {
            VStack {
                Spacer()
                selectionPill("\(star.artistName.uppercased()) · ALBUM \(star.sequence)")
                    .accessibilityIdentifier("aeon.sky.star-selection")
            }
            .padding(.bottom, 24)
        }
    }

    private func selectionPill(_ text: String) -> some View {
        Text(text)
            .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
            .tracking(1.4)
            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            .padding(.horizontal, AeonTheme.Space.regular)
            .frame(minHeight: AeonTheme.Space.minimumTarget)
            .background(
                Capsule().fill(AeonTheme.ColorToken.chamber.opacity(0.88))
            )
            .overlay(
                Capsule().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
            )
    }
}

private struct SkyLabelOverlay: View {
    @ObservedObject var controller: SkySceneController
    let viewport: CGSize
    let highContrast: Bool

    var body: some View {
        ZStack {
            ForEach(labels.prefix(80)) { label in
                Text(label.text)
                    .font(.system(size: label.isRegion ? 12 : 10, weight: .medium, design: .monospaced))
                    .tracking(label.isRegion ? 1.6 : 0.8)
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary.opacity(highContrast ? 1 : (label.isRegion ? 0.9 : 0.82)))
                    .shadow(color: .black, radius: 3)
                    .position(label.position)
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
                let center = SkyPoint(
                    x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                    y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count))
                )
                return Label(id: region.id, text: region.name.uppercased(), position: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: true)
            }.filter(visible)
        }
        return controller.catalogue.constellations.compactMap { constellation in
            let points = constellation.albumIDs.compactMap { starByID[$0]?.coordinate }
            guard !points.isEmpty else { return nil }
            let center = SkyPoint(
                x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count))
            )
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
